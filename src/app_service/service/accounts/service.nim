import NimQml, Tables, os, json, stew/shims/strformat, sequtils, strutils, uuids, times, std/options
import json_serialization, chronicles

import ../../../app/global/global_singleton
import ./dto/accounts as dto_accounts
import ./dto/generated_accounts as dto_generated_accounts
import ./dto/login_request
import ./dto/create_account_request
import ./dto/restore_account_request

from ../keycard/service import KeycardEvent, KeyDetails
import ../../../backend/general as status_general
import ../../../backend/core as status_core
import ../../../backend/privacy as status_privacy

import ../../../app/core/eventemitter
import ../../../app/core/signals/types
import ../../../app/core/tasks/[qt, threadpool]
import ../../../app/core/fleets/fleet_configuration
import ../../common/[account_constants, network_constants, utils]
import ../../../constants as main_constants

import ../settings/dto/settings as settings

export dto_accounts
export dto_generated_accounts


logScope:
  topics = "accounts-service"

const DEFAULT_WALLET_ACCOUNT_NAME = "Account 1"
const PATHS = @[PATH_WALLET_ROOT, PATH_EIP_1581, PATH_WHISPER, PATH_DEFAULT_WALLET, PATH_ENCRYPTION]
const ACCOUNT_ALREADY_EXISTS_ERROR* =  "account already exists"
const KDF_ITERATIONS* {.intdefine.} = 256_000
const DEFAULT_CUSTOMIZATION_COLOR = "primary"  # to match `CustomizationColor` on the go side

# allow runtime override via environment variable. core contributors can set a
# specific peer to set for testing messaging and mailserver functionality with squish.
let TEST_PEER_ENR = getEnv("TEST_PEER_ENR").string

const SIGNAL_CONVERTING_PROFILE_KEYPAIR* = "convertingProfileKeypair"
const SIGNAL_DERIVED_ADDRESSES_FROM_NOT_IMPORTED_MNEMONIC_FETCHED* = "derivedAddressesFromNotImportedMnemonicFetched"
const SIGNAL_LOGIN_ERROR* = "errorWhileLogin"

type ResultArgs* = ref object of Args
  success*: bool

type LoginErrorArgs* = ref object of Args
  error*: string

type DerivedAddressesFromNotImportedMnemonicArgs* = ref object of Args
  error*: string
  derivations*: Table[string, DerivedAccountDetails]

include utils
include async_tasks
include ../../common/async_tasks

QtObject:
  type Service* = ref object of QObject
    events: EventEmitter
    threadpool: ThreadPool
    fleetConfiguration: FleetConfiguration
    generatedAccounts: seq[GeneratedAccountDto]
    accounts: seq[AccountDto]
    loggedInAccount: AccountDto
    importedAccount: GeneratedAccountDto
    keyStoreDir: string
    defaultWalletEmoji: string
    tmpAccount: AccountDto
    tmpHashedPassword: string

  proc delete*(self: Service) =
    self.QObject.delete

  proc newService*(events: EventEmitter, threadpool: ThreadPool, fleetConfiguration: FleetConfiguration): Service =
    new(result, delete)
    result.QObject.setup
    result.events = events
    result.threadpool = threadpool
    result.fleetConfiguration = fleetConfiguration
    result.keyStoreDir = main_constants.ROOTKEYSTOREDIR
    result.defaultWalletEmoji = ""

  proc setLocalAccountSettingsFile(self: Service) =
    if self.loggedInAccount.isValid():
      singletonInstance.localAccountSettings.setFileName(self.loggedInAccount.name)

  proc getLoggedInAccount*(self: Service): AccountDto =
    return self.loggedInAccount

  proc setLoggedInAccount*(self: Service, account: AccountDto) =
    self.loggedInAccount = account
    self.setLocalAccountSettingsFile()

  proc updateLoggedInAccount*(self: Service, displayName: string, images: seq[Image]) =
    self.loggedInAccount.name = displayName
    self.loggedInAccount.images = images
    singletonInstance.localAccountSettings.setFileName(displayName)

  proc getImportedAccount*(self: Service): GeneratedAccountDto =
    return self.importedAccount

  proc setKeyStoreDir(self: Service, key: string) =
    self.keyStoreDir = joinPath(main_constants.ROOTKEYSTOREDIR, key) & main_constants.sep
    discard status_general.initKeystore(self.keyStoreDir)

  proc getKeyStoreDir*(self: Service): string =
    return self.keyStoreDir

  proc setDefaultWalletEmoji*(self: Service, emoji: string) =
    self.defaultWalletEmoji = emoji

  proc connectToFetchingFromWakuEvents*(self: Service) =
    self.events.on(SignalType.WakuBackedUpProfile.event) do(e: Args):
      var receivedData = WakuBackedUpProfileSignal(e)
      self.updateLoggedInAccount(receivedData.backedUpProfile.displayName, receivedData.backedUpProfile.images)

  proc init*(self: Service) =
    try:
      let response = status_account.generateAddresses(PATHS)

      self.generatedAccounts = map(response.result.getElems(),
      proc(x: JsonNode): GeneratedAccountDto = toGeneratedAccountDto(x))

      for account in self.generatedAccounts.mitems:
        account.alias = generateAliasFromPk(account.derivedAccounts.whisper.publicKey)

    except Exception as e:
      error "error: ", procName="init", errName = e.name, errDesription = e.msg

  proc clear*(self: Service) =
    self.generatedAccounts = @[]
    self.loggedInAccount = AccountDto()
    self.importedAccount = GeneratedAccountDto()

  proc validateMnemonic*(self: Service, mnemonic: string): (string, string) =
    try:
      let response = status_general.validateMnemonic(mnemonic)
      if response.result.contains("error"):
        return ("", response.result["error"].getStr)
      return (response.result["keyUID"].getStr, "")
    except Exception as e:
      error "error: ", procName="validateMnemonic", errName = e.name, errDesription = e.msg

  proc generatedAccounts*(self: Service): seq[GeneratedAccountDto] =
    if(self.generatedAccounts.len == 0):
      error "There was some issue initiating account service"
      return

    result = self.generatedAccounts

  proc openedAccounts*(self: Service): seq[AccountDto] =
    try:
      let response = status_account.openedAccounts(main_constants.STATUSGODIR)

      self.accounts = map(response.result.getElems(), proc(x: JsonNode): AccountDto = toAccountDto(x))

      return self.accounts

    except Exception as e:
      error "error: ", procName="openedAccounts", errName = e.name, errDesription = e.msg

  proc openedAccountsContainsKeyUid*(self: Service, keyUid: string): bool =
    return (keyUID in self.openedAccounts().mapIt(it.keyUid))

  proc saveKeycardAccountAndLogin(self: Service, chatKey, password: string, account, subaccounts, settings,
    config: JsonNode): AccountDto =
    try:
      let response = status_account.saveAccountAndLoginWithKeycard(chatKey, password, account, subaccounts, settings, config)

      var error = "response doesn't contain \"error\""
      if(response.result.contains("error")):
        error = response.result["error"].getStr
        if error == "":
          debug "Account saved succesfully"
          result = toAccountDto(account)
          return

      let err = "Error saving account and logging in via keycard : " & error
      error "error: ", procName="saveKeycardAccountAndLogin", errDesription = err

    except Exception as e:
      error "error: ", procName="saveKeycardAccountAndLogin", errName = e.name, errDesription = e.msg

  proc prepareSubaccountJsonObject(self: Service, account: GeneratedAccountDto, displayName: string):
    JsonNode =
    result = %* [
      {
        "public-key": account.derivedAccounts.defaultWallet.publicKey,
        "address": account.derivedAccounts.defaultWallet.address,
        "colorId": DEFAULT_CUSTOMIZATION_COLOR,
        "wallet": true,
        "path": PATH_DEFAULT_WALLET,
        "name": DEFAULT_WALLET_ACCOUNT_NAME,
        "derived-from": account.address,
        "emoji": self.defaultWalletEmoji
      },
      {
        "public-key": account.derivedAccounts.whisper.publicKey,
        "address": account.derivedAccounts.whisper.address,
        "name": if displayName == "": account.alias else: displayName,
        "path": PATH_WHISPER,
        "chat": true,
        "derived-from": ""
      }
    ]

  proc getSubaccountDataForAccountId(self: Service, accountId: string, displayName: string): JsonNode =
    for acc in self.generatedAccounts:
      if(acc.id == accountId):
        return self.prepareSubaccountJsonObject(acc, displayName)

    if(self.importedAccount.isValid()):
      if(self.importedAccount.id == accountId):
        return self.prepareSubaccountJsonObject(self.importedAccount, displayName)

  proc toStatusGoSupportedLogLevel*(logLevel: string): string =
    if logLevel == "TRACE":
      return "DEBUG"
    return logLevel

  proc prepareAccountSettingsJsonObject(self: Service, account: GeneratedAccountDto,
    installationId: string, displayName: string, withoutMnemonic: bool): JsonNode =
    result = %* {
      "key-uid": account.keyUid,
      "mnemonic": if withoutMnemonic: "" else: account.mnemonic,
      "public-key": account.derivedAccounts.whisper.publicKey,
      "name": account.alias,
      "display-name": displayName,
      "address": account.address,
      "eip1581-address": account.derivedAccounts.eip1581.address,
      "dapps-address": account.derivedAccounts.defaultWallet.address,
      "wallet-root-address": account.derivedAccounts.walletRoot.address,
      "preview-privacy?": true,
      "signing-phrase": generateSigningPhrase(3),
      "log-level": main_constants.LOG_LEVEL,
      "latest-derived-path": 0,
      "currency": "usd",
      "networks/networks": @[],
      "networks/current-network": "",
      "wallet/visible-tokens": {},
      "waku-enabled": true,
      "appearance": 0,
      "installation-id": installationId,
      "current-user-status": %* {
          "publicKey": account.derivedAccounts.whisper.publicKey,
          "statusType": 1,
          "clock": 0,
          "text": ""
        },
      "profile-pictures-show-to": settings.PROFILE_PICTURES_SHOW_TO_EVERYONE,
      "profile-pictures-visibility": settings.PROFILE_PICTURES_VISIBILITY_EVERYONE,
      "url-unfurling-mode": int(settings.UrlUnfurlingMode.AlwaysAsk),
    }

  proc getAccountSettings(self: Service, accountId: string, installationId: string, displayName: string, withoutMnemonic: bool): JsonNode =
    for acc in self.generatedAccounts:
      if(acc.id == accountId):
        return self.prepareAccountSettingsJsonObject(acc, installationId, displayName, withoutMnemonic)

    if(self.importedAccount.isValid()):
      if(self.importedAccount.id == accountId):
        return self.prepareAccountSettingsJsonObject(self.importedAccount, installationId, displayName, withoutMnemonic)

  # TODO: Remove after https://github.com/status-im/status-go/issues/4977
  proc getDefaultNodeConfig*(self: Service, installationId: string, recoverAccount: bool): JsonNode =
    let fleet = Fleet.ShardsTest
    let dnsDiscoveryURL = "enrtree://AMOJVZX4V6EXP7NTJPMAYJYST2QP6AJXYW76IU6VGJS7UVSNDYZG4@boot.test.shards.nodes.status.im"

    result = NODE_CONFIG.copy()
    result["ClusterConfig"]["Fleet"] = newJString($fleet)
    result["NetworkId"] = NETWORKS[0]{"chainId"}
    result["DataDir"] = "ethereum".newJString()
    result["UpstreamConfig"]["Enabled"] = true.newJBool()
    result["UpstreamConfig"]["URL"] = NETWORKS[0]{"rpcUrl"}
    result["ShhextConfig"]["InstallationID"] = newJString(installationId)


    result["ClusterConfig"]["WakuNodes"] = %* @[dnsDiscoveryURL]

    var discV5Bootnodes = self.fleetConfiguration.getNodes(fleet, FleetNodes.WakuENR)
    discV5Bootnodes.add(dnsDiscoveryURL)

    result["ClusterConfig"]["DiscV5BootstrapNodes"] = %* discV5Bootnodes

    if TEST_PEER_ENR != "":
      let testPeerENRArr = %* @[TEST_PEER_ENR]
      result["ClusterConfig"]["WakuNodes"] = %* testPeerENRArr
      result["ClusterConfig"]["BootNodes"] = %* testPeerENRArr
      result["ClusterConfig"]["TrustedMailServers"] = %* testPeerENRArr
      result["ClusterConfig"]["StaticNodes"] = %* testPeerENRArr
      result["ClusterConfig"]["RendezvousNodes"] = %* (@[])
      result["ClusterConfig"]["DiscV5BootstrapNodes"] = %* (@[])
      result["Rendezvous"] = newJBool(false)

    result["LogLevel"] = newJString(toStatusGoSupportedLogLevel(main_constants.LOG_LEVEL))

    if STATUS_PORT != 0:
      result["ListenAddr"] = newJString("0.0.0.0:" & $main_constants.STATUS_PORT)

    result["KeyStoreDir"] = newJString(self.keyStoreDir.replace(main_constants.STATUSGODIR, ""))
    result["RootDataDir"] = newJString(main_constants.STATUSGODIR)
    result["KeycardPairingDataFile"] = newJString(main_constants.KEYCARDPAIRINGDATAFILE)
    result["ProcessBackedupMessages"] = newJBool(recoverAccount)

  # TODO: Remove after https://github.com/status-im/status-go/issues/4977
  proc getLoginNodeConfig(self: Service): JsonNode =
    # To create appropriate NodeConfig for Login we set only params that maybe be set via env variables or cli flags
    result = %*{}

    # mandatory params
    result["NetworkId"] = NETWORKS[0]{"chainId"}
    result["DataDir"] = %* "./ethereum/mainnet"
    result["KeyStoreDir"] = %* self.keyStoreDir.replace(main_constants.STATUSGODIR, "")
    result["KeycardPairingDataFile"] = %* main_constants.KEYCARDPAIRINGDATAFILE

    # other params
    result["Networks"] = NETWORKS

    result["UpstreamConfig"] = %* {
      "URL": NETWORKS[0]{"rpcUrl"},
      "Enabled": true,
    }

    result["ShhextConfig"] = %* {
      "VerifyENSURL": NETWORKS[0]{"fallbackUrl"},
      "VerifyTransactionURL": NETWORKS[0]{"fallbackUrl"}
    }

    result["WakuV2Config"] = %* {
      "Port": WAKU_V2_PORT,
      "UDPPort": WAKU_V2_PORT
    }

    result["WalletConfig"] = NODE_CONFIG["WalletConfig"]

    result["TorrentConfig"] = %* {
      "Port": TORRENT_CONFIG_PORT,
      "DataDir": DEFAULT_TORRENT_CONFIG_DATADIR,
      "TorrentDir": DEFAULT_TORRENT_CONFIG_TORRENTDIR
    }

    if main_constants.runtimeLogLevelSet():
      result["RuntimeLogLevel"] = newJString(toStatusGoSupportedLogLevel(main_constants.LOG_LEVEL))

    if STATUS_PORT != 0:
      result["ListenAddr"] = newJString("0.0.0.0:" & $main_constants.STATUS_PORT)

  proc addKeycardDetails(self: Service, kcInstance: string, settingsJson: var JsonNode, accountData: var JsonNode) =
    let keycardPairingJsonString = readFile(main_constants.KEYCARDPAIRINGDATAFILE)
    let keycardPairingJsonObj = keycardPairingJsonString.parseJSON
    let now = now().toTime().toUnix()
    for instanceUid, kcDataObj in keycardPairingJsonObj:
      if instanceUid != kcInstance:
        continue
      if not settingsJson.isNil:
        settingsJson["keycard-instance-uid"] = %* instanceUid
        settingsJson["keycard-paired-on"] = %* now
        settingsJson["keycard-pairing"] = kcDataObj{"key"}
      if not accountData.isNil:
        accountData["keycard-pairing"] = kcDataObj{"key"}

  proc buildWalletSecrets(self: Service): WalletSecretsConfig =
    return WalletSecretsConfig(
      poktToken: POKT_TOKEN_RESOLVED,
      infuraToken: INFURA_TOKEN_RESOLVED,
      infuraSecret: INFURA_TOKEN_SECRET_RESOLVED,
      openseaApiKey: OPENSEA_API_KEY_RESOLVED,
      raribleMainnetApiKey: RARIBLE_MAINNET_API_KEY_RESOLVED,
      raribleTestnetApiKey: RARIBLE_TESTNET_API_KEY_RESOLVED,
      alchemyEthereumMainnetToken: ALCHEMY_ETHEREUM_MAINNET_TOKEN_RESOLVED,
      alchemyEthereumGoerliToken: ALCHEMY_ETHEREUM_GOERLI_TOKEN_RESOLVED,
      alchemyEthereumSepoliaToken: ALCHEMY_ETHEREUM_SEPOLIA_TOKEN_RESOLVED,
      alchemyArbitrumMainnetToken: ALCHEMY_ARBITRUM_MAINNET_TOKEN_RESOLVED,
      alchemyArbitrumGoerliToken: ALCHEMY_ARBITRUM_GOERLI_TOKEN_RESOLVED,
      alchemyArbitrumSepoliaToken: ALCHEMY_ARBITRUM_SEPOLIA_TOKEN_RESOLVED,
      alchemyOptimismMainnetToken: ALCHEMY_OPTIMISM_MAINNET_TOKEN_RESOLVED,
      alchemyOptimismGoerliToken: ALCHEMY_OPTIMISM_GOERLI_TOKEN_RESOLVED,
      alchemyOptimismSepoliaToken: ALCHEMY_OPTIMISM_SEPOLIA_TOKEN_RESOLVED,
    )

  proc buildCreateAccountRequest(self: Service, password: string, displayName: string, imagePath: string, imageCropRectangle: ImageCropRectangle): CreateAccountRequest =
    return CreateAccountRequest(
        backupDisabledDataDir: main_constants.STATUSGODIR,
        kdfIterations: KDF_ITERATIONS,
        password: hashPassword(password),
        displayName: displayName,
        imagePath: imagePath,
        imageCropRectangle: imageCropRectangle,
        customizationColor: DEFAULT_CUSTOMIZATION_COLOR,
        emoji: self.defaultWalletEmoji,
        logLevel: some(toStatusGoSupportedLogLevel(main_constants.LOG_LEVEL)),
        wakuV2LightClient: false,
        previewPrivacy: true,
        torrentConfigEnabled: some(false),
        torrentConfigPort: some(TORRENT_CONFIG_PORT),
        walletSecretsConfig: self.buildWalletSecrets(),
      )

  proc createAccountAndLogin*(self: Service, password: string, displayName: string, imagePath: string, imageCropRectangle: ImageCropRectangle): string =
    try:
      let request = self.buildCreateAccountRequest(password, displayName, imagePath, imageCropRectangle)
      let response = status_account.createAccountAndLogin(request)
      
      if not response.result.contains("error"):
        error "invalid status-go response", response
        return "invalid response: no error field found"

      let error = response.result["error"].getStr
      if error == "":
        debug "Account saved succesfully"
        return ""
      
      error "createAccountAndLogin status-go error: ", error
      return "createAccountAndLogin failed: " & error

    except Exception as e:
      error "failed to create account or login", procName="createAccountAndLogin", errName = e.name, errDesription = e.msg
      return e.msg

  proc importAccountAndLogin*(self: Service, mnemonic: string, password: string, recoverAccount: bool, displayName: string, imagePath: string, imageCropRectangle: ImageCropRectangle): string =
    try:
      let request = RestoreAccountRequest(
        mnemonic: mnemonic,
        fetchBackup: recoverAccount,
        createAccountRequest: self.buildCreateAccountRequest(password, displayName, imagePath, imageCropRectangle),
      )
      let response = status_account.restoreAccountAndLogin(request)

      if not response.result.contains("error"):
        error "invalid status-go response", response
        return "invalid response: no error field found"

      let error = response.result["error"].getStr
      if error == "":
        debug "Account saved succesfully"
        return ""

      error "importAccountAndLogin status-go error: ", error
      return "importAccountAndLogin failed: " & error

    except Exception as e:
      error "failed to import account or login", procName="importAccountAndLogin", errName = e.name, errDesription = e.msg
      return e.msg

  proc setupAccountKeycard*(self: Service, keycardData: KeycardEvent, displayName: string, useImportedAcc: bool,
    recoverAccount: bool = false) =
    try:
      var keyUid = keycardData.keyUid
      var address = keycardData.masterKey.address
      var whisperPrivateKey = keycardData.whisperKey.privateKey
      var whisperPublicKey = keycardData.whisperKey.publicKey
      var whisperAddress = keycardData.whisperKey.address
      var walletPublicKey = keycardData.walletKey.publicKey
      var walletAddress = keycardData.walletKey.address
      var walletRootAddress = keycardData.walletRootKey.address
      var eip1581Address = keycardData.eip1581Key.address
      var encryptionPublicKey = keycardData.encryptionKey.publicKey
      if useImportedAcc:
        keyUid = self.importedAccount.keyUid
        address = self.importedAccount.address
        whisperPublicKey = self.importedAccount.derivedAccounts.whisper.publicKey
        whisperAddress = self.importedAccount.derivedAccounts.whisper.address
        walletPublicKey = self.importedAccount.derivedAccounts.defaultWallet.publicKey
        walletAddress = self.importedAccount.derivedAccounts.defaultWallet.address
        walletRootAddress = self.importedAccount.derivedAccounts.walletRoot.address
        eip1581Address = self.importedAccount.derivedAccounts.eip1581.address
        encryptionPublicKey = self.importedAccount.derivedAccounts.encryption.publicKey
        whisperPrivateKey = self.importedAccount.derivedAccounts.whisper.privateKey

      if whisperPrivateKey.startsWith("0x"):
        whisperPrivateKey = whisperPrivateKey[2 .. ^1]

      let installationId = $genUUID()
      let alias = generateAliasFromPk(whisperPublicKey)

      var accountDataJson = %* {
        "name": if displayName == "": alias else: displayName,
        "display-name": displayName,
        "address": address,
        "key-uid": keyUid,
        "kdfIterations": KDF_ITERATIONS,
      }

      self.setKeyStoreDir(keyUid)
      let nodeConfigJson = self.getDefaultNodeConfig(installationId, recoverAccount)
      let subaccountDataJson = %* [
        {
          "public-key": walletPublicKey,
          "address": walletAddress,
          "colorId": DEFAULT_CUSTOMIZATION_COLOR,
          "wallet": true,
          "path": PATH_DEFAULT_WALLET,
          "name": DEFAULT_WALLET_ACCOUNT_NAME,
          "derived-from": address,
          "emoji": self.defaultWalletEmoji,
        },
        {
          "public-key": whisperPublicKey,
          "address": whisperAddress,
          "name": if displayName == "": alias else: displayName,
          "path": PATH_WHISPER,
          "chat": true,
          "derived-from": ""
        }
      ]

      var settingsJson = %* {
        "key-uid": keyUid,
        "public-key": whisperPublicKey,
        "name": alias,
        "display-name": displayName,
        "address": address,
        "eip1581-address": eip1581Address,
        "dapps-address":  walletAddress,
        "wallet-root-address": walletRootAddress,
        "preview-privacy?": true,
        "signing-phrase": generateSigningPhrase(3),
        "log-level": main_constants.LOG_LEVEL,
        "latest-derived-path": 0,
        "currency": "usd",
        "networks/networks": @[],
        "networks/current-network": "",
        "wallet/visible-tokens": {},
        "waku-enabled": true,
        "appearance": 0,
        "installation-id": installationId,
        "current-user-status": {
          "publicKey": whisperPublicKey,
          "statusType": 1,
          "clock": 0,
          "text": ""
        }
      }

      self.addKeycardDetails(keycardData.instanceUID, settingsJson, accountDataJson)

      if(accountDataJson.isNil or subaccountDataJson.isNil or settingsJson.isNil or
        nodeConfigJson.isNil):
        let description = "at least one json object is not prepared well"
        error "error: ", procName="setupAccountKeycard", errDesription = description
        return

      self.loggedInAccount = self.saveKeycardAccountAndLogin(chatKey = whisperPrivateKey,
        password = encryptionPublicKey,
        accountDataJson,
        subaccountDataJson,
        settingsJson,
        nodeConfigJson)
      self.setLocalAccountSettingsFile()
    except Exception as e:
      error "error: ", procName="setupAccount", errName = e.name, errDesription = e.msg

  proc createAccountFromPrivateKey*(self: Service, privateKey: string): GeneratedAccountDto =
    if privateKey.len == 0:
      error "empty private key"
      return
    try:
      let response = status_account.createAccountFromPrivateKey(privateKey)
      return toGeneratedAccountDto(response.result)
    except Exception as e:
      error "error: ", procName="createAccountFromPrivateKey", errName = e.name, errDesription = e.msg

  proc createAccountFromMnemonic*(self: Service, mnemonic: string, paths: seq[string]): GeneratedAccountDto =
    if mnemonic.len == 0:
      error "empty mnemonic"
      return
    try:
      let response = status_account.createAccountFromMnemonicAndDeriveAccountsForPaths(mnemonic, paths)
      return toGeneratedAccountDto(response.result)
    except Exception as e:
      error "error: ", procName="createAccountFromMnemonicAndDeriveAccountsForPaths", errName = e.name, errDesription = e.msg

  proc createAccountFromMnemonic*(self: Service, mnemonic: string, includeEncryption = false, includeWhisper = false,
    includeRoot = false, includeDefaultWallet = false, includeEip1581 = false): GeneratedAccountDto =
    var paths: seq[string]
    if includeEncryption:
      paths.add(PATH_ENCRYPTION)
    if includeWhisper:
      paths.add(PATH_WHISPER)
    if includeRoot:
      paths.add(PATH_WALLET_ROOT)
    if includeDefaultWallet:
      paths.add(PATH_DEFAULT_WALLET)
    if includeEip1581:
      paths.add(PATH_EIP_1581)
    return self.createAccountFromMnemonic(mnemonic, paths)

  proc fetchAddressesFromNotImportedMnemonic*(self: Service, mnemonic: string, paths: seq[string])=
    let arg = FetchAddressesFromNotImportedMnemonicArg(
      mnemonic: mnemonic,
      paths: paths,
      tptr: fetchAddressesFromNotImportedMnemonicTask,
      vptr: cast[ByteAddress](self.vptr),
      slot: "onAddressesFromNotImportedMnemonicFetched",
    )
    self.threadpool.start(arg)

  proc onAddressesFromNotImportedMnemonicFetched*(self: Service, jsonString: string) {.slot.} =
    var data = DerivedAddressesFromNotImportedMnemonicArgs()
    try:
      let response = parseJson(jsonString)
      data.error = response["error"].getStr()
      if data.error.len == 0:
        data.derivations = toGeneratedAccountDto(response["derivedAddresses"]).derivedAccounts.derivations
    except Exception as e:
      error "error: ", procName="fetchAddressesFromNotImportedMnemonic", errName = e.name, errDesription = e.msg
      data.error = e.msg
    self.events.emit(SIGNAL_DERIVED_ADDRESSES_FROM_NOT_IMPORTED_MNEMONIC_FETCHED, data)

  proc importMnemonic*(self: Service, mnemonic: string): string =
    if mnemonic.len == 0:
      return "empty mnemonic"
    try:
      let response = status_account.multiAccountImportMnemonic(mnemonic)
      self.importedAccount = toGeneratedAccountDto(response.result)

      if (self.accounts.contains(self.importedAccount.keyUid)):
        return ACCOUNT_ALREADY_EXISTS_ERROR

      let responseDerived = status_account.deriveAccounts(self.importedAccount.id, PATHS)
      self.importedAccount.derivedAccounts = toDerivedAccounts(responseDerived.result)

      self.importedAccount.alias= generateAliasFromPk(self.importedAccount.derivedAccounts.whisper.publicKey)

      if (not self.importedAccount.isValid()):
        return "imported account is not valid"
    except Exception as e:
      error "error: ", procName="importMnemonic", errName = e.name, errDesription = e.msg
      return e.msg

  proc verifyAccountPassword*(self: Service, account: string, password: string): bool =
    try:
      let response = status_account.verifyAccountPassword(account, utils.hashPassword(password), self.keyStoreDir)
      if(response.result.contains("error")):
        let errMsg = response.result["error"].getStr
        if(errMsg.len == 0):
          return true
        else:
          error "error: ", procName="verifyAccountPassword", errDesription = errMsg
      return false
    except Exception as e:
      error "error: ", procName="verifyAccountPassword", errName = e.name, errDesription = e.msg

  proc verifyDatabasePassword*(self: Service, keyuid: string, hashedPassword: string): bool =
    try:
      let response = status_account.verifyDatabasePassword(keyuid, hashedPassword)
      if(response.result.contains("error")):
        let errMsg = response.result["error"].getStr
        if(errMsg.len == 0):
          return true
        else:
          error "error: ", procName="verifyDatabasePassword", errDesription = errMsg
      return false
    except Exception as e:
      error "error: ", procName="verifyDatabasePassword", errName = e.name, errDesription = e.msg

  proc doLogin(self: Service, account: AccountDto, passwordHash: string) =
    var request = LoginAccountRequest(
      keyUid: account.keyUid,
      kdfIterations: account.kdfIterations,
      passwordHash: passwordHash,
      walletSecretsConfig: self.buildWalletSecrets(),
      bandwidthStatsEnabled: true,
    )

    if main_constants.runtimeLogLevelSet():
      request.runtimeLogLevel = toStatusGoSupportedLogLevel(main_constants.LOG_LEVEL)

    let response = status_account.loginAccount(request)

    if response.result{"error"}.getStr != "":
      self.events.emit(SIGNAL_LOGIN_ERROR, LoginErrorArgs(error: response.result{"error"}.getStr))
      return

    debug "account logged in"
    self.setLocalAccountSettingsFile()

  proc login*(self: Service, account: AccountDto, hashedPassword: string) =
    try:
      let keyStoreDir = joinPath(main_constants.ROOTKEYSTOREDIR, account.keyUid) & main_constants.sep
      if not dirExists(keyStoreDir):
        os.createDir(keyStoreDir)
        status_core.migrateKeyStoreDir($ %* {
          "key-uid": account.keyUid
        }, hashedPassword, main_constants.ROOTKEYSTOREDIR, keyStoreDir)

      self.setKeyStoreDir(account.keyUid)

      let isOldHashPassword = self.verifyDatabasePassword(account.keyUid, hashedPasswordToUpperCase(hashedPassword))
      if isOldHashPassword:
        debug "database reencryption scheduled"

        # Save tmp properties so that we can login after the timer
        self.tmpAccount = account
        self.tmpHashedPassword = hashedPassword

        # Start a 1 second timer for the loading screen to appear
        let arg = TimerTaskArg(
          tptr: timerTask,
          vptr: cast[ByteAddress](self.vptr),
          slot: "onWaitForReencryptionTimeout",
          timeoutInMilliseconds: 1000
        )
        self.threadpool.start(arg)
        return

      self.doLogin(account, hashedPassword)

    except Exception as e:
      error "login failed", errName = e.name, errDesription = e.msg
      self.events.emit(SIGNAL_LOGIN_ERROR, LoginErrorArgs(error: e.msg))

  proc onWaitForReencryptionTimeout(self: Service, response: string) {.slot.} =
    debug "starting database reencryption"

    # Reencryption (can freeze and take up to 30 minutes)
    let oldHashedPassword = hashedPasswordToUpperCase(self.tmpHashedPassword)
    discard status_privacy.changeDatabasePassword(self.tmpAccount.keyUid, oldHashedPassword, self.tmpHashedPassword)

    # Normal login after reencryption
    self.doLogin(self.tmpAccount, self.tmpHashedPassword)

    # Clear out the temp properties
    self.tmpAccount = AccountDto()
    self.tmpHashedPassword = ""

  proc loginAccountKeycard*(self: Service, accToBeLoggedIn: AccountDto, keycardData: KeycardEvent): string =
    try:
      self.setKeyStoreDir(keycardData.keyUid)

      var accountDataJson = %* {
        "key-uid": accToBeLoggedIn.keyUid,
      }

      let nodeConfigJson = self.getLoginNodeConfig()

      let response = status_account.loginWithKeycard(keycardData.whisperKey.privateKey,
        keycardData.encryptionKey.publicKey,
        accountDataJson,
        nodeConfigJson)

      var error = "response doesn't contain \"error\""
      if(response.result.contains("error")):
        error = response.result["error"].getStr
        if error == "":
          debug "Account logged in succesfully"
          # this should be fetched later from waku
          self.loggedInAccount = accToBeLoggedIn
          self.setLocalAccountSettingsFile()
          return
    except Exception as e:
      error "keycard login failed", procName="loginAccountKeycard", errName = e.name, errDesription = e.msg
      return e.msg

  proc convertRegularProfileKeypairToKeycard*(self: Service, keycardUid, currentPassword: string, newPassword: string) =
    var accountDataJson = %* {
      "key-uid": self.getLoggedInAccount().keyUid,
      "kdfIterations": KDF_ITERATIONS
    }
    var settingsJson = %* { }

    self.addKeycardDetails(keycardUid, settingsJson, accountDataJson)

    let hashedCurrentPassword = hashPassword(currentPassword)
    let arg = ConvertRegularProfileKeypairToKeycardTaskArg(
      tptr: convertRegularProfileKeypairToKeycardTask,
      vptr: cast[ByteAddress](self.vptr),
      slot: "onConvertRegularProfileKeypairToKeycard",
      accountDataJson: accountDataJson,
      settingsJson: settingsJson,
      keycardUid: keycardUid,
      hashedCurrentPassword: hashedCurrentPassword,
      newPassword: newPassword
    )

    DB_BLOCKED_DUE_TO_PROFILE_MIGRATION = true
    self.threadpool.start(arg)

  proc onConvertRegularProfileKeypairToKeycard*(self: Service, response: string) {.slot.} =
    var result = false
    try:
      let rpcResponse = Json.decode(response, RpcResponse[JsonNode])
      if(rpcResponse.result.contains("error")):
        let errMsg = rpcResponse.result["error"].getStr
        if(errMsg.len == 0):
          result = true
        else:
          error "error: ", procName="onConvertRegularProfileKeypairToKeycard", errDesription = errMsg
    except Exception as e:
      error "error handilng migrated keypair response", procName="onConvertRegularProfileKeypairToKeycard", errDesription=e.msg
    self.events.emit(SIGNAL_CONVERTING_PROFILE_KEYPAIR, ResultArgs(success: result))

  proc convertKeycardProfileKeypairToRegular*(self: Service, mnemonic: string, currentPassword: string, newPassword: string) =
    let hashedNewPassword = hashPassword(newPassword)
    let arg = ConvertKeycardProfileKeypairToRegularTaskArg(
      tptr: convertKeycardProfileKeypairToRegularTask,
      vptr: cast[ByteAddress](self.vptr),
      slot: "onConvertKeycardProfileKeypairToRegular",
      mnemonic: mnemonic,
      currentPassword: currentPassword,
      hashedNewPassword: hashedNewPassword
    )

    DB_BLOCKED_DUE_TO_PROFILE_MIGRATION = true
    self.threadpool.start(arg)

  proc onConvertKeycardProfileKeypairToRegular*(self: Service, response: string) {.slot.} =
    var result = false
    try:
      let rpcResponse = Json.decode(response, RpcResponse[JsonNode])
      if(rpcResponse.result.contains("error")):
        let errMsg = rpcResponse.result["error"].getStr
        if(errMsg.len == 0):
          result = true
        else:
          error "error: ", procName="onConvertKeycardProfileKeypairToRegular", errDesription = errMsg
    except Exception as e:
      error "error handilng migrated keypair response", procName="onConvertKeycardProfileKeypairToRegular", errDesription=e.msg
    self.events.emit(SIGNAL_CONVERTING_PROFILE_KEYPAIR, ResultArgs(success: result))

  proc verifyPassword*(self: Service, password: string): bool =
    try:
      let hashedPassword = hashPassword(password)
      let response = status_account.verifyPassword(hashedPassword)
      return response.result.getBool
    except Exception as e:
      error "error: ", procName="verifyPassword", errName = e.name, errDesription = e.msg
    return false

  proc getKdfIterations*(self: Service): int =
    return KDF_ITERATIONS

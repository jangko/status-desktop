import NimQml, chronicles

import ./controller, ./view
import ./io_interface as io_interface
import ../io_interface as delegate_interface

import ./accounts/module as accounts_module
import ./all_tokens/module as all_tokens_module
import ./collectibles/module as collectibles_module
import ./current_account/module as current_account_module
import ./transactions/module as transactions_module
import ./saved_addresses/module as saved_addresses_module
import ./buy_sell_crypto/module as buy_sell_crypto_module
import ./add_account/module as add_account_module

import ../../../global/global_singleton
import ../../../core/eventemitter
import ../../../../app_service/service/keycard/service as keycard_service
import ../../../../app_service/service/token/service as token_service
import ../../../../app_service/service/currency/service as currency_service
import ../../../../app_service/service/transaction/service as transaction_service
import ../../../../app_service/service/collectible/service as collectible_service
import ../../../../app_service/service/wallet_account/service as wallet_account_service
import ../../../../app_service/service/settings/service as settings_service
import ../../../../app_service/service/saved_address/service as saved_address_service
import ../../../../app_service/service/network/service as network_service
import ../../../../app_service/service/accounts/service as accounts_service
import ../../../../app_service/service/node/service as node_service
import ../../../../app_service/service/network_connection/service as network_connection_service

logScope:
  topics = "wallet-section-module"

import io_interface
export io_interface

type
  Module* = ref object of io_interface.AccessInterface
    delegate: delegate_interface.AccessInterface
    events: EventEmitter
    moduleLoaded: bool
    controller: Controller
    view: View

    accountsModule: accounts_module.AccessInterface
    allTokensModule: all_tokens_module.AccessInterface
    collectiblesModule: collectibles_module.AccessInterface
    currentAccountModule: current_account_module.AccessInterface
    transactionsModule: transactions_module.AccessInterface
    savedAddressesModule: saved_addresses_module.AccessInterface
    buySellCryptoModule: buy_sell_crypto_module.AccessInterface
    addAccountModule: add_account_module.AccessInterface
    keycardService: keycard_service.Service
    accountsService: accounts_service.Service
    walletAccountService: wallet_account_service.Service

proc newModule*(
  delegate: delegate_interface.AccessInterface,
  events: EventEmitter,
  tokenService: token_service.Service,
  currencyService: currency_service.Service,
  transactionService: transaction_service.Service,
  collectibleService: collectible_service.Service,
  walletAccountService: wallet_account_service.Service,
  settingsService: settings_service.Service,
  savedAddressService: saved_address_service.Service,
  networkService: network_service.Service,
  accountsService: accounts_service.Service,
  keycardService: keycard_service.Service,
  nodeService: node_service.Service,
  networkConnectionService: network_connection_service.Service
): Module =
  result = Module()
  result.delegate = delegate
  result.events = events
  result.keycardService = keycardService
  result.accountsService = accountsService
  result.walletAccountService = walletAccountService
  result.moduleLoaded = false
  result.controller = newController(result, settingsService, walletAccountService, currencyService)
  result.view = newView(result)

  result.accountsModule = accounts_module.newModule(result, events, walletAccountService, networkService, currencyService)
  result.allTokensModule = all_tokens_module.newModule(result, events, tokenService, walletAccountService)
  result.collectiblesModule = collectibles_module.newModule(result, events, collectibleService, walletAccountService, networkService, nodeService, networkConnectionService)
  result.currentAccountModule = current_account_module.newModule(result, events, walletAccountService, networkService, tokenService, currencyService)
  result.transactionsModule = transactions_module.newModule(result, events, transactionService, walletAccountService, networkService, currencyService)
  result.savedAddressesModule = saved_addresses_module.newModule(result, events, savedAddressService)
  result.buySellCryptoModule = buy_sell_crypto_module.newModule(result, events, transactionService)

method delete*(self: Module) =
  self.accountsModule.delete
  self.allTokensModule.delete
  self.collectiblesModule.delete
  self.currentAccountModule.delete
  self.transactionsModule.delete
  self.savedAddressesModule.delete
  self.buySellCryptoModule.delete
  self.controller.delete
  self.view.delete
  if not self.addAccountModule.isNil:
    self.addAccountModule.delete

method updateCurrency*(self: Module, currency: string) =
  self.controller.updateCurrency(currency)

method switchAccount*(self: Module, accountIndex: int) =
  self.currentAccountModule.switchAccount(accountIndex)
  self.collectiblesModule.switchAccount(accountIndex)
  self.transactionsModule.switchAccount(accountIndex)

method switchAccountByAddress*(self: Module, address: string) =
  let accountIndex = self.controller.getIndex(address)
  self.switchAccount(accountIndex)

method setTotalCurrencyBalance*(self: Module) =
  self.view.setTotalCurrencyBalance(self.controller.getCurrencyBalance())

method getCurrencyAmount*(self: Module, amount: float64, symbol: string): CurrencyAmount =
  return self.controller.getCurrencyAmount(amount, symbol)

method load*(self: Module) =
  singletonInstance.engine.setRootContextProperty("walletSection", newQVariant(self.view))

  self.events.on(SIGNAL_WALLET_ACCOUNT_SAVED) do(e:Args):
    self.setTotalCurrencyBalance()
  self.events.on(SIGNAL_WALLET_ACCOUNT_DELETED) do(e:Args):
    self.switchAccount(0)
    self.setTotalCurrencyBalance()
  self.events.on(SIGNAL_WALLET_ACCOUNT_CURRENCY_UPDATED) do(e:Args):
    self.view.setCurrentCurrency(self.controller.getCurrency())
    self.setTotalCurrencyBalance()
  self.events.on(SIGNAL_WALLET_ACCOUNT_NETWORK_ENABLED_UPDATED) do(e:Args):
    self.setTotalCurrencyBalance()
  self.events.on(SIGNAL_WALLET_ACCOUNT_TOKENS_REBUILT) do(e:Args):
    self.setTotalCurrencyBalance()
  self.events.on(SIGNAL_CURRENCY_FORMATS_UPDATED) do(e:Args):
    self.setTotalCurrencyBalance()

  self.controller.init()
  self.view.load()
  self.accountsModule.load()
  self.allTokensModule.load()
  self.collectiblesModule.load()
  self.currentAccountModule.load()
  self.transactionsModule.load()
  self.savedAddressesModule.load()
  self.buySellCryptoModule.load()

method isLoaded*(self: Module): bool =
  return self.moduleLoaded

proc checkIfModuleDidLoad(self: Module) =
  if(not self.accountsModule.isLoaded()):
    return

  if(not self.allTokensModule.isLoaded()):
    return

  if(not self.collectiblesModule.isLoaded()):
    return

  if(not self.currentAccountModule.isLoaded()):
    return

  if(not self.transactionsModule.isLoaded()):
    return

  if(not self.savedAddressesModule.isLoaded()):
    return

  if(not self.buySellCryptoModule.isLoaded()):
    return

  self.switchAccount(0)
  let currency = self.controller.getCurrency()
  let signingPhrase = self.controller.getSigningPhrase()
  let mnemonicBackedUp = self.controller.isMnemonicBackedUp()
  self.view.setData(currency, signingPhrase, mnemonicBackedUp)
  self.setTotalCurrencyBalance()

  self.moduleLoaded = true
  self.delegate.walletSectionDidLoad()

method viewDidLoad*(self: Module) =
  self.checkIfModuleDidLoad()

method accountsModuleDidLoad*(self: Module) =
  self.checkIfModuleDidLoad()

method allTokensModuleDidLoad*(self: Module) =
  self.checkIfModuleDidLoad()

method collectiblesModuleDidLoad*(self: Module) =
  self.checkIfModuleDidLoad()

method currentAccountModuleDidLoad*(self: Module) =
  self.checkIfModuleDidLoad()

method transactionsModuleDidLoad*(self: Module) =
  self.checkIfModuleDidLoad()

method savedAddressesModuleDidLoad*(self: Module) =
  self.checkIfModuleDidLoad()

method buySellCryptoModuleDidLoad*(self: Module) =
  self.checkIfModuleDidLoad()

method destroyAddAccountPopup*(self: Module, switchToAccWithAddress: string = "") =
  if not self.addAccountModule.isNil:
    if switchToAccWithAddress.len > 0:
      self.switchAccountByAddress(switchToAccWithAddress)
    self.view.emitDestroyAddAccountPopup()
    self.addAccountModule.delete
    self.addAccountModule = nil

method runAddAccountPopup*(self: Module) =
  self.destroyAddAccountPopup()
  self.addAccountModule = add_account_module.newModule(self, self.events, self.keycardService, self.accountsService, 
    self.walletAccountService)
  self.addAccountModule.load()

method getAddAccountModule*(self: Module): QVariant =
  if self.addAccountModule.isNil:
    return newQVariant()
  return self.addAccountModule.getModuleAsVariant()

method onAddAccountModuleLoaded*(self: Module) =
  self.view.emitDisplayAddAccountPopup()
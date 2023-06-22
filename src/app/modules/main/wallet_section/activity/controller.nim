import NimQml, logging, std/json, sequtils, sugar, options, strutils, times
import tables, stint, sets, atomics

import model
import entry
import recipients_model

import web3/conversions

import ../transactions/item
import ../transactions/module as transactions_module

import app/core/eventemitter
import app/core/signals/types

import backend/activity as backend_activity
import backend/backend as backend
import backend/transactions

import app_service/service/currency/service as currency_service
import app_service/service/transaction/service as transaction_service
import app_service/service/token/service as token_service

proc toRef*[T](obj: T): ref T =
  new(result)
  result[] = obj

const FETCH_BATCH_COUNT_DEFAULT = 10
const FETCH_RECIPIENTS_BATCH_COUNT_DEFAULT = 2000

type EventCallbackProc = proc (eventObject: JsonNode)

# TODO: implement passing of collectibles
QtObject:
  type
    Controller* = ref object of QObject
      model: Model
      recipientsModel: RecipientsModel
      transactionsModule: transactions_module.AccessInterface
      currentActivityFilter: backend_activity.ActivityFilter
      currencyService: currency_service.Service
      tokenService: token_service.Service

      events: EventEmitter
      # Event name and handler pairs
      eventHandlers: Table[string, EventCallbackProc]

      loadingData: Atomic[int]
      errorCode: backend_activity.ErrorCode

      loadingRecipients: Atomic[int]
      loadingStartTimestamp: Atomic[int]

      # call updateAssetsIdentities after updating filterTokenCodes
      filterTokenCodes: HashSet[string]

      addresses: seq[string]
      # call updateAssetsIdentities after updating chainIds
      chainIds: seq[int]

      startTimestamp: int

  proc setup(self: Controller) =
    self.QObject.setup

  proc delete*(self: Controller) =
    self.QObject.delete

  proc getModel*(self: Controller): QVariant {.slot.} =
    return newQVariant(self.model)

  QtProperty[QVariant] model:
    read = getModel

  proc getRecipientsModel*(self: Controller): QVariant {.slot.} =
    return newQVariant(self.recipientsModel)

  QtProperty[QVariant] recipientsModel:
    read = getRecipientsModel

  proc buildMultiTransactionExtraData(self: Controller, metadata: backend_activity.ActivityEntry, item: MultiTransactionDto): ExtraData =
    # TODO: Use symbols from backendEntry when they're available
    result.inSymbol = item.toAsset
    result.inAmount = self.currencyService.parseCurrencyValue(result.inSymbol, metadata.amountIn)
    result.outSymbol = item.fromAsset
    result.outAmount = self.currencyService.parseCurrencyValue(result.outSymbol, metadata.amountOut)

  proc buildTransactionExtraData(self: Controller, metadata: backend_activity.ActivityEntry, item: ref Item): ExtraData =
    # TODO: Use symbols from backendEntry when they're available
    result.inSymbol = item[].getSymbol()
    result.inAmount = self.currencyService.parseCurrencyValue(result.inSymbol, metadata.amountIn)
    result.outSymbol = item[].getSymbol()
    result.outAmount = self.currencyService.parseCurrencyValue(result.outSymbol, metadata.amountOut)

  proc backendToPresentation(self: Controller, backendEntities: seq[backend_activity.ActivityEntry]): seq[entry.ActivityEntry] =
    var multiTransactionsIds: seq[int] = @[]
    var transactionIdentities: seq[backend.TransactionIdentity] = @[]
    var pendingTransactionIdentities: seq[backend.TransactionIdentity] = @[]

    # Extract metadata required to fetch details
    # TODO: temporary here to show the working API. Details for each entry will be done as required
    # on a detail request from UI after metadata is extended to include the required info
    for backendEntry in backendEntities:
      case backendEntry.payloadType:
        of MultiTransaction:
          multiTransactionsIds.add(backendEntry.id)
        of SimpleTransaction:
          transactionIdentities.add(backendEntry.transaction.get())
        of PendingTransaction:
          pendingTransactionIdentities.add(backendEntry.transaction.get())

    var multiTransactions = initTable[int, MultiTransactionDto]()
    if len(multiTransactionsIds) > 0:
      let mts = transaction_service.getMultiTransactions(multiTransactionsIds)
      for mt in mts:
        multiTransactions[mt.id] = mt

    var transactions = initTable[TransactionIdentity, ref Item]()
    if len(transactionIdentities) > 0:
      let response = backend.getTransfersForIdentities(transactionIdentities)
      let res = response.result
      if response.error != nil or res.kind != JArray or res.len == 0:
        raise newException(Defect, "failed fetching transaction details")

      let transactionsDtos = res.getElems().map(x => x.toTransactionDto())
      let trItems = self.transactionsModule.transactionsToItems(transactionsDtos, @[])
      for item in trItems:
        transactions[TransactionIdentity(chainId: item.getChainId(), hash: item.getId(), address: item.getAddress())] = toRef(item)

    var pendingTransactions = initTable[TransactionIdentity, ref Item]()
    if len(pendingTransactionIdentities) > 0:
      let response = backend.getPendingTransactionsForIdentities(pendingTransactionIdentities)
      let res = response.result
      if response.error != nil or res.kind != JArray or res.len == 0:
        raise newException(Defect, "failed fetching pending transactions details")

      let pendingTransactionsDtos = res.getElems().map(x => x.toPendingTransactionDto())
      let trItems = self.transactionsModule.transactionsToItems(pendingTransactionsDtos, @[])
      for item in trItems:
        pendingTransactions[TransactionIdentity(chainId: item.getChainId(), hash: item.getId(), address: item.getAddress())] = toRef(item)

    # Merge detailed transaction info in order
    result = newSeqOfCap[entry.ActivityEntry](multiTransactions.len + transactions.len + pendingTransactions.len)
    var mtIndex = 0
    var tIndex = 0
    var ptIndex = 0
    for backendEntry in backendEntities:
      case backendEntry.payloadType:
        of MultiTransaction:
          let id = multiTransactionsIds[mtIndex]
          if multiTransactions.hasKey(id):
            let mt = multiTransactions[id]
            let extraData = self.buildMultiTransactionExtraData(backendEntry, mt)
            result.add(entry.newMultiTransactionActivityEntry(mt, backendEntry, extraData))
          else:
            error "failed to find multi transaction with id: ", id
          mtIndex += 1
        of SimpleTransaction:
          let identity = transactionIdentities[tIndex]
          if transactions.hasKey(identity):
            let tr = transactions[identity]
            let extraData = self.buildTransactionExtraData(backendEntry, tr)
            result.add(entry.newTransactionActivityEntry(tr, backendEntry, self.addresses, extraData))
          else:
            error "failed to find transaction with identity: ", identity
          tIndex += 1
        of PendingTransaction:
          let identity = pendingTransactionIdentities[ptIndex]
          if pendingTransactions.hasKey(identity):
            let tr = pendingTransactions[identity]
            let extraData = self.buildTransactionExtraData(backendEntry, tr)
            result.add(entry.newTransactionActivityEntry(tr, backendEntry, self.addresses, extraData))
          else:
            error "failed to find pending transaction with identity: ", identity
          ptIndex += 1

  proc loadingDataChanged*(self: Controller) {.signal.}

  proc setLoadingData(self: Controller, loadingData: bool) =
    discard fetchAdd(self.loadingData, if loadingData: 1 else: -1)
    self.loadingDataChanged()

  proc loadingRecipientsChanged*(self: Controller) {.signal.}

  proc setLoadingRecipients(self: Controller, loadingData: bool) =
    discard fetchAdd(self.loadingRecipients, if loadingData: 1 else: -1)
    self.loadingRecipientsChanged()

  proc loadingStartTimestampChanged*(self: Controller) {.signal.}

  proc setLoadingStartTimestamp(self: Controller, loadingData: bool) =
    discard fetchAdd(self.loadingStartTimestamp, if loadingData: 1 else: -1)
    self.loadingStartTimestampChanged()

  proc errorCodeChanged*(self: Controller) {.signal.}

  proc setErrorCode(self: Controller, errorCode: int) =
    self.errorCode = backend_activity.ErrorCode(errorCode)
    self.errorCodeChanged()

  proc processResponse(self: Controller, response: JsonNode) =
    defer: self.setLoadingData(false)

    let res = fromJson(response, backend_activity.FilterResponse)

    defer: self.setErrorCode(res.errorCode.int)

    if res.errorCode != ErrorCodeSuccess:
      error "error fetching activity entries: ", res.errorCode
      return

    let entries = self.backendToPresentation(res.activities)
    self.model.setEntries(entries, res.offset, res.hasMore)

  proc updateFilter*(self: Controller) {.slot.} =
    self.setLoadingData(true)
    self.model.resetModel(@[])

    let response = backend_activity.filterActivityAsync(self.addresses, seq[backend_activity.ChainId](self.chainIds), self.currentActivityFilter, 0, FETCH_BATCH_COUNT_DEFAULT)
    if response.error != nil:
      error "error fetching activity entries: ", response.error
      self.setLoadingData(false)
      return

  proc loadMoreItems(self: Controller) {.slot.} =
    self.setLoadingData(true)

    let response = backend_activity.filterActivityAsync(self.addresses, seq[backend_activity.ChainId](self.chainIds), self.currentActivityFilter, self.model.getCount(), FETCH_BATCH_COUNT_DEFAULT)
    if response.error != nil:
      self.setLoadingData(false)
      error "error fetching activity entries: ", response.error
      return

  proc setFilterTime*(self: Controller, startTimestamp: int, endTimestamp: int) {.slot.} =
    self.currentActivityFilter.period = backend_activity.newPeriod(startTimestamp, endTimestamp)

  proc setFilterType*(self: Controller, typesArrayJsonString: string) {.slot.} =
    let typesJson = parseJson(typesArrayJsonString)
    if typesJson.kind != JArray:
      error "invalid array of json ints"
      return

    var types = newSeq[backend_activity.ActivityType](typesJson.len)
    for i in 0 ..< typesJson.len:
      types[i] = backend_activity.ActivityType(typesJson[i].getInt())

    self.currentActivityFilter.types = types

  proc startTimestampChanged*(self: Controller) {.signal.}

  # Call this method on every data update (ideally only if updates are before the last timestamp retrieved)
  # This depends on self.addresses being set, call on every address change
  proc updateStartTimestamp*(self: Controller) {.slot.} =
    self.setLoadingStartTimestamp(true)

    let resJson = backend_activity.getOldestActivityTimestampAsync(self.addresses)
    if resJson.error != nil:
      self.setLoadingStartTimestamp(false)
      error "error requesting oldest activity timestamp: ", resJson.error
      return

  proc handleApiEvents(self: Controller, e: Args) =
    var data = WalletSignal(e)

    if self.eventHandlers.hasKey(data.eventType):
      var responseJson: JsonNode
      responseJson = parseJson(data.message)

      if responseJson.kind != JObject:
        error "unexpected json type", responseJson.kind
        return
      let callback = self.eventHandlers[data.eventType]
      callback(responseJson)
    else:
      discard

  proc setupEventHandlers(self: Controller) =
    self.eventHandlers[backend_activity.eventActivityFilteringDone] = proc (jsonObj: JsonNode) =
      self.processResponse(jsonObj)

    self.eventHandlers[backend_activity.eventActivityGetRecipientsDone] = proc (jsonObj: JsonNode) =
      defer: self.setLoadingRecipients(false)
      let res = fromJson(jsonObj, backend_activity.GetRecipientsResponse)

      if res.errorCode != ErrorCodeSuccess:
        error "error fetching recipients: ", res.errorCode
        return

      self.recipientsModel.addAddresses(res.addresses, res.offset, res.hasMore)

    self.eventHandlers[backend_activity.eventActivityGetOldestTimestampDone] = proc (jsonObj: JsonNode) =
      defer: self.setLoadingStartTimestamp(false)
      let res = fromJson(jsonObj, backend_activity.GetOldestTimestampResponse)

      if res.errorCode != ErrorCodeSuccess:
        error "error fetching start timestamp: ", res.errorCode
        return

      self.startTimestamp = res.timestamp
      self.startTimestampChanged()

  proc newController*(transactionsModule: transactions_module.AccessInterface,
                      currencyService: currency_service.Service,
                      tokenService: token_service.Service,
                      events: EventEmitter): Controller =
    new(result, delete)
    result.model = newModel()
    result.recipientsModel = newRecipientsModel()
    result.transactionsModule = transactionsModule
    result.tokenService = tokenService
    result.currentActivityFilter = backend_activity.getIncludeAllActivityFilter()
    result.events = events
    result.eventHandlers = initTable[string, EventCallbackProc]()
    result.currencyService = currencyService

    result.errorCode = backend_activity.ErrorCode.ErrorCodeSuccess

    result.filterTokenCodes = initHashSet[string]()

    result.addresses = @[]
    result.chainIds = @[]

    result.setup()

    result.setupEventHandlers()
    let controller = result
    result.events.on(SignalType.Wallet.event, proc(e: Args) =
        controller.handleApiEvents(e)
    )

  proc setFilterStatus*(self: Controller, statusesArrayJsonString: string) {.slot.} =
    let statusesJson = parseJson(statusesArrayJsonString)
    if statusesJson.kind != JArray:
      error "invalid array of json ints"
      return

    var statuses = newSeq[backend_activity.ActivityStatus](statusesJson.len)
    for i in 0 ..< statusesJson.len:
      statuses[i] = backend_activity.ActivityStatus(statusesJson[i].getInt())

    self.currentActivityFilter.statuses = statuses

  proc setFilterToAddresses*(self: Controller, addressesArrayJsonString: string) {.slot.} =
    let addressesJson = parseJson(addressesArrayJsonString)
    if addressesJson.kind != JArray:
      error "invalid array of json strings"
      return

    var addresses = newSeq[string](addressesJson.len)
    for i in 0 ..< addressesJson.len:
      addresses[i] = addressesJson[i].getStr()

    self.currentActivityFilter.counterpartyAddresses = addresses

  # Depends on self.filterTokenCodes and self.chainIds, so should be called after updating them
  proc updateAssetsIdentities(self: Controller) =
    var assets = newSeq[backend_activity.Token]()
    for tokenCode in self.filterTokenCodes:
      for chainId in self.chainIds:
        let token = self.tokenService.findTokenBySymbol(chainId, tokenCode)
        if token != nil:
          let tokenType = if token.symbol == "ETH": backend_activity.TokenType.Native else: backend_activity.TokenType.Erc20
          assets.add(backend_activity.Token(
            tokenType: tokenType,
            chainId: backend_activity.ChainId(token.chainId),
            address: some(token.address)
          ))

    self.currentActivityFilter.assets = assets

  proc setFilterAssets*(self: Controller, assetsArrayJsonString: string, excludeAssets: bool) {.slot.} =
    self.filterTokenCodes.clear()
    if excludeAssets:
      return

    let assetsJson = parseJson(assetsArrayJsonString)
    if assetsJson.kind != JArray:
      error "invalid array of json strings"
      return

    for i in 0 ..< assetsJson.len:
      let tokenCode = assetsJson[i].getStr()
      self.filterTokenCodes.incl(tokenCode)

    self.updateAssetsIdentities()

  proc setFilterAddresses*(self: Controller, addresses: seq[string]) =
    self.addresses = addresses

    self.updateStartTimestamp()

  proc setFilterToAddresses*(self: Controller, addresses: seq[string]) =
    self.currentActivityFilter.counterpartyAddresses = addresses

  proc setFilterChains*(self: Controller, chainIds: seq[int]) =
    self.chainIds = chainIds

    self.updateAssetsIdentities()

  proc getLoadingData*(self: Controller): bool {.slot.} =
    return load(self.loadingData) > 0

  QtProperty[bool] loadingData:
    read = getLoadingData
    notify = loadingDataChanged

  proc getErrorCode*(self: Controller): int {.slot.} =
    return self.errorCode.int

  QtProperty[int] errorCode:
    read = getErrorCode
    notify = errorCodeChanged

  proc getLoadingRecipients*(self: Controller): bool {.slot.} =
    return load(self.loadingRecipients) > 0

  QtProperty[bool] loadingRecipients:
    read = getLoadingRecipients
    notify = loadingRecipientsChanged

  proc getLoadingStartTimestamp*(self: Controller): bool {.slot.} =
    return load(self.loadingStartTimestamp) > 0

  QtProperty[bool] loadingStartTimestamp:
    read = getLoadingStartTimestamp
    notify = loadingStartTimestampChanged

  proc updateRecipientsModel*(self: Controller) {.slot.} =
    self.setLoadingRecipients(true)
    let res = backend_activity.getRecipientsAsync(0, FETCH_RECIPIENTS_BATCH_COUNT_DEFAULT)
    if res.error != nil or res.result.kind != JBool:
      self.setLoadingRecipients(false)
      error "error fetching recipients: ", res.error, "; kind ", res.result.kind
      return

    # If the request was enqueued and already waiting for a response, we don't need to do anything
    if res.result.getBool():
      self.setLoadingRecipients(false)

  proc loadMoreRecipients(self: Controller) {.slot.} =
    self.setLoadingRecipients(true)
    let res = backend_activity.getRecipientsAsync(self.recipientsModel.getCount(), FETCH_RECIPIENTS_BATCH_COUNT_DEFAULT)
    if res.error != nil:
      self.setLoadingRecipients(false)
      error "error fetching more recipient entries: ", res.error
      return

    # If the request was enqueued and waiting for an answer, we don't need to do anything
    if res.result.getBool():
      self.setLoadingRecipients(false)

  proc getStartTimestamp*(self: Controller): int {.slot.} =
    return  if self.startTimestamp > 0:
              self.startTimestamp
            else:
              int(times.parse("2000-01-01", "yyyy-MM-dd").toTime().toUnix())

  QtProperty[int] startTimestamp:
    read = getStartTimestamp
    notify = startTimestampChanged

  proc updateFilterBase(self: Controller) {.slot.} =
    self.updateStartTimestamp()

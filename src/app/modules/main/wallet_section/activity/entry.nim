import NimQml, tables, json, strformat, sequtils, strutils, logging

import ../transactions/view
import ../transactions/item
import ./backend/transactions

# The ActivityEntry contains one of the following instances transaction, pensing transaction or multi-transaction
# It is used to display an activity history entry in the QML UI
QtObject:
  type
    ActivityEntry* = ref object of QObject
      multi_transaction: MultiTransactionDto
      transaction: ref Item
      isPending: bool

  proc setup(self: ActivityEntry) =
    self.QObject.setup

  proc delete*(self: ActivityEntry) =
    self.QObject.delete

  proc newMultiTransactionActivityEntry*(mt: MultiTransactionDto): ActivityEntry =
    new(result, delete)
    result.multi_transaction = mt
    result.transaction = nil
    result.isPending = false
    result.setup()

  proc newTransactionActivityEntry*(tr: ref Item, isPending: bool): ActivityEntry =
    new(result, delete)
    result.multi_transaction = nil
    result.transaction = tr
    result.isPending = isPending
    result.setup()

  proc isMultiTransaction*(self: ActivityEntry): bool {.slot.} =
    return self.multi_transaction != nil

  QtProperty[bool] isMultiTransaction:
    read = isMultiTransaction

  proc isPendingTransaction*(self: ActivityEntry): bool {.slot.} =
    return (not self.isMultiTransaction()) and self.isPending

  QtProperty[bool] isPendingTransaction:
    read = isPendingTransaction

  proc `$`*(self: ActivityEntry): string =
    let mtStr = if self.multi_transaction != nil: $(self.multi_transaction.id) else: "0"
    let trStr = if self.transaction != nil: $(self.transaction[]) else: "nil"

    return fmt"""ActivityEntry(
      multi_transaction.id:{mtStr},
      transaction:{trStr},
      isPending:{self.isPending}
    )"""

  proc getMultiTransaction*(self: ActivityEntry): MultiTransactionDto =
    if not self.isMultiTransaction():
      raise newException(Defect, "ActivityEntry is not a MultiTransaction")
    return self.multi_transaction

  proc getTransaction*(self: ActivityEntry, pending: bool): ref Item =
    if self.isMultiTransaction() or self.isPending != pending:
      raise newException(Defect, "ActivityEntry is not a " & (if pending: "pending" else: "") & " Transaction")
    return self.transaction

  proc getSender*(self: ActivityEntry): string {.slot.} =
    # TODO: lookup sender's name from addressbook and cache it or in advance
    if self.isMultiTransaction():
      return self.multi_transaction.fromAddress

    return self.transaction[].getfrom()

  QtProperty[string] sender:
    read = getSender

  proc getRecipient*(self: ActivityEntry): string {.slot.} =
    # TODO: lookup recipient name from addressbook and cache it or in advance
    if self.isMultiTransaction():
      return self.multi_transaction.toAddress

    return self.transaction[].getTo()

  QtProperty[string] recipient:
    read = getRecipient

  # TODO: use CurrencyAmount?
  proc getFromAmount*(self: ActivityEntry): string {.slot.} =
    if self.isMultiTransaction():
      return self.multi_transaction.fromAmount
    error "getFromAmount: ActivityEntry is not a MultiTransaction"
    return "0"

  QtProperty[string] fromAmount:
    read = getFromAmount

  proc getToAmount*(self: ActivityEntry): string {.slot.} =
    if not self.isMultiTransaction():
      error "getToAmount: ActivityEntry is not a MultiTransaction"
      return "0"

    return self.multi_transaction.fromAmount

  QtProperty[string] toAmount:
    read = getToAmount

  proc getAmount*(self: ActivityEntry): QVariant {.slot.} =
    if not self.isMultiTransaction():
      error "getAmount: ActivityEntry is not an transaction.Item"
      return newQVariant(0)

    return newQVariant(self.transaction[].getValue())

  QtProperty[QVariant] amount:
    read = getAmount

  proc getTimestamp*(self: ActivityEntry): int {.slot.} =
    if self.isMultiTransaction():
      return self.multi_transaction.timestamp
    # TODO: should we account for self.transaction[].isTimeStamp?
    return self.transaction[].getTimestamp()

  QtProperty[int] timestamp:
    read = getTimestamp

  # TODO: properties - type, fromChains, toChains, fromAsset, toAsset, assetName
import NimQml, os, strformat, strutils, parseUtils
import stint
import ../../status/status
import ../../status/stickers
import ../../status/libstatus/accounts/constants as accountConstants
import ../../status/libstatus/tokens
import ../../status/libstatus/wallet as status_wallet
import ../../status/libstatus/utils as status_utils
import ../../status/ens as status_ens
import web3/[ethtypes, conversions]

QtObject:
  type UtilsView* = ref object of QObject
    status*: Status

  proc setup(self: UtilsView) =
    self.QObject.setup

  proc delete*(self: UtilsView) =
    self.QObject.delete

  proc newUtilsView*(status: Status): UtilsView =
    new(result, delete)
    result = UtilsView()
    result.status = status
    result.setup

  proc getDataDir*(self: UtilsView): string {.slot.} =
    result = accountConstants.DATADIR

  proc joinPath*(self: UtilsView, start: string, ending: string): string {.slot.} =
    result = os.joinPath(start, ending)

  proc join3Paths*(self: UtilsView, start: string, middle: string, ending: string): string {.slot.} =
    result = os.joinPath(start, middle, ending)

  proc getSNTAddress*(self: UtilsView): string {.slot.} =
    result = getSNTAddress()

  proc getSNTBalance*(self: UtilsView): string {.slot.} =
    let currAcct = status_wallet.getWalletAccounts()[0]
    result = getSNTBalance($currAcct.address)

  proc eth2Wei*(self: UtilsView, eth: string, decimals: int): string {.slot.} =
    let uintValue = status_utils.eth2Wei(parseFloat(eth), decimals)
    return uintValue.toString()

  proc wei2Token*(self: UtilsView, wei: string, decimals: int): string {.slot.} =
    return status_utils.wei2Token(wei, decimals)

  proc getStickerMarketAddress(self: UtilsView): string {.slot.} =
    $self.status.stickers.getStickerMarketAddress

  QtProperty[string] stickerMarketAddress:
    read = getStickerMarketAddress

  proc getEnsRegisterAddress(self: UtilsView): QVariant {.slot.} =
    newQVariant($statusRegistrarAddress())

  QtProperty[QVariant] ensRegisterAddress:
    read = getEnsRegisterAddress

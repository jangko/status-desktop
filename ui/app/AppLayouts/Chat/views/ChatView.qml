import QtQuick 2.13
import QtQuick.Controls 2.13
import Qt.labs.settings 1.0

import utils 1.0
import shared 1.0
import shared.panels 1.0
import shared.popups 1.0
import shared.status 1.0
import shared.stores 1.0
import shared.views.chat 1.0
import shared.stores.send 1.0
import SortFilterProxyModel 0.2

import StatusQ.Core 0.1
import StatusQ.Core.Theme 0.1
import StatusQ.Layout 0.1
import StatusQ.Popups 0.1
import StatusQ.Controls 0.1
import QtQuick.Layouts 1.15

import "."
import "../panels"
import AppLayouts.Communities.panels 1.0
import AppLayouts.Communities.views 1.0
import AppLayouts.Communities.controls 1.0
import AppLayouts.Wallet.stores 1.0 as WalletStore
import "../popups"
import "../helpers"
import "../controls"
import "../stores"

StatusSectionLayout {
    id: root

    property var contactsStore
    property bool hasAddedContacts: contactsStore.myContactsModel.count > 0

    property RootStore rootStore
    required property TransactionStore transactionStore
    property var createChatPropertiesStore
    property var communitiesStore
    required property WalletStore.WalletAssetsStore walletAssetsStore
    required property CurrenciesStore currencyStore
    property var sectionItemModel

    property var emojiPopup
    property var stickersPopup
    property bool stickersLoaded: false

    readonly property var chatContentModule: rootStore.currentChatContentModule() || null
    readonly property bool canView: chatContentModule.chatDetails.canView
    readonly property bool canPost: chatContentModule.chatDetails.canPost

    property bool hasViewOnlyPermissions: false
    property bool hasUnrestrictedViewOnlyPermission: false

    property bool hasViewAndPostPermissions: false
    property bool amIMember: false
    property bool amISectionAdmin: false
    readonly property bool allChannelsAreHiddenBecauseNotPermitted: rootStore.allChannelsAreHiddenBecauseNotPermitted

    property int requestToJoinState: Constants.RequestToJoinState.None

    property var viewOnlyPermissionsModel
    property var viewAndPostPermissionsModel
    property var assetsModel
    property var collectiblesModel

    readonly property bool contentLocked: {
        if (!rootStore.chatCommunitySectionModule.isCommunity()) {
            return false
        }
        if (!amIMember) {
            if (hasUnrestrictedViewOnlyPermission)
                return false

            return hasViewAndPostPermissions || hasViewOnlyPermissions
        }
        if (amISectionAdmin) {
            return false
        }
        if (!hasViewAndPostPermissions && hasViewOnlyPermissions) {
            return !canView
        }
        if (hasViewAndPostPermissions && !hasViewOnlyPermissions) {
            return !canPost
        }
        if (hasViewOnlyPermissions && hasViewAndPostPermissions) {
            return !canView && !canPost
        }
        return false
    }

    // Community transfer ownership related props:
    required property bool isPendingOwnershipRequest
    signal finaliseOwnershipClicked

    signal communityInfoButtonClicked()
    signal communityManageButtonClicked()
    signal profileButtonClicked()
    signal openAppSearch()

    signal requestToJoinClicked
    signal invitationPendingClicked

    Connections {
        target: root.rootStore.stickersStore.stickersModule

        function onStickerPacksLoaded() {
            root.stickersLoaded = true;
        }
    }

    Connections {
        target: root.rootStore.chatCommunitySectionModule
        ignoreUnknownSignals: true

        function onActiveItemChanged() {
            Global.closeCreateChatView()
        }
    }

    onNotificationButtonClicked: Global.openActivityCenterPopup()
    notificationCount: activityCenterStore.unreadNotificationsCount
    hasUnseenNotifications: activityCenterStore.hasUnseenNotifications

    headerContent: Loader {
        visible: !root.allChannelsAreHiddenBecauseNotPermitted
        id: headerContentLoader
        sourceComponent: root.contentLocked ? joinCommunityHeaderPanelComponent : chatHeaderContentViewComponent
    }

    leftPanel: Loader {
        id: contactColumnLoader
        sourceComponent: root.rootStore.chatCommunitySectionModule.isCommunity()?
                             communtiyColumnComponent :
                             contactsColumnComponent
    }

    centerPanel: Loader {
        anchors.fill: parent
        sourceComponent: (root.allChannelsAreHiddenBecauseNotPermitted || root.contentLocked) ?
                             joinCommunityCenterPanelComponent : chatColumnViewComponent
    }

    showRightPanel: {
        if (root.contentLocked) {
            return false
        }

        if (root.rootStore.openCreateChat ||
           !localAccountSensitiveSettings.showOnlineUsers ||
           !localAccountSensitiveSettings.expandUsersList) {
            return false
        }

        let chatContentModule = root.rootStore.currentChatContentModule()
        if (!chatContentModule) {
            return false
        }
        // Check if user list is available as an option for particular chat content module
        return chatContentModule.chatDetails.isUsersListAvailable
    }

    rightPanel: Component {
        id: userListComponent
        UserListPanel {
            anchors.fill: parent
            store: root.rootStore
            label: qsTr("Members")
            communityMemberReevaluationStatus: root.rootStore.communityMemberReevaluationStatus
            usersModel: root.chatContentModule && root.chatContentModule.usersModule ? root.chatContentModule.usersModule.model : null
        }
    }

    Component {
        id: chatHeaderContentViewComponent
        ChatHeaderContentView {
            visible: !!root.rootStore.currentChatContentModule()
            rootStore: root.rootStore
            emojiPopup: root.emojiPopup
            onSearchButtonClicked: root.openAppSearch()
            onDisplayEditChannelPopup: {
                Global.openPopup(contactColumnLoader.item.createChannelPopup, {
                    isEdit: true,
                    chatId: chatId,
                    channelName: chatName,
                    channelDescription: chatDescription,
                    channelEmoji: chatEmoji,
                    channelColor: chatColor,
                    categoryId: chatCategoryId,
                    channelPosition: channelPosition,
                    deleteChatConfirmationDialog: deleteDialog,
                    hideIfPermissionsNotMet: hideIfPermissionsNotMet
                });
            }
        }
    }

    Component {
        id: joinCommunityHeaderPanelComponent
        JoinCommunityHeaderPanel {
            readonly property var chatContentModule: root.rootStore.currentChatContentModule() || null
            joinCommunity: false
            color: chatContentModule.chatDetails.color
            channelName: chatContentModule.chatDetails.name
            channelDesc: chatContentModule.chatDetails.description
        }
    }

    Component {
        id: chatColumnViewComponent

        ChatColumnView {
            parentModule: root.rootStore.chatCommunitySectionModule
            rootStore: root.rootStore
            createChatPropertiesStore: root.createChatPropertiesStore
            contactsStore: root.contactsStore
            stickersLoaded: root.stickersLoaded
            emojiPopup: root.emojiPopup
            stickersPopup: root.stickersPopup
            viewAndPostHoldingsModel: root.viewAndPostPermissionsModel
            canPost: !root.rootStore.chatCommunitySectionModule.isCommunity() || root.canPost
            amISectionAdmin: root.amISectionAdmin
            onOpenStickerPackPopup: {
                Global.openPopup(statusStickerPackClickPopup, {packId: stickerPackId, store: root.stickersPopup.store} )
            }
        }
    }

    Component {
        id: joinCommunityCenterPanelComponent

        JoinCommunityCenterPanel {
            joinCommunity: false
            allChannelsAreHiddenBecauseNotPermitted: root.allChannelsAreHiddenBecauseNotPermitted
            name: sectionItemModel.name
            channelName: root.chatContentModule.chatDetails.name
            viewOnlyHoldingsModel: root.viewOnlyPermissionsModel
            viewAndPostHoldingsModel: root.viewAndPostPermissionsModel
            assetsModel: root.assetsModel
            collectiblesModel: root.collectiblesModel
            requestToJoinState: root.requestToJoinState
            requiresRequest: !root.amIMember
            requirementsMet: (canView && viewOnlyPermissionsModel.count > 0) ||
                             (canPost && viewAndPostPermissionsModel.count > 0)
            requirementsCheckPending: root.chatContentModule.permissionsCheckOngoing
            onRequestToJoinClicked: root.requestToJoinClicked()
            onInvitationPendingClicked: root.invitationPendingClicked()
        }
    }

    Component {
        id: contactsColumnComponent
        ContactsColumnView {
            chatSectionModule: root.rootStore.chatCommunitySectionModule
            store: root.rootStore
            contactsStore: root.contactsStore
            emojiPopup: root.emojiPopup
            onOpenProfileClicked: {
                root.profileButtonClicked();
            }

            onOpenAppSearch: {
                root.openAppSearch()
            }
            onAddRemoveGroupMemberClicked: {
                if (headerContentLoader.item && headerContentLoader.item instanceof ChatHeaderContentView) {
                    headerContentLoader.item.addRemoveGroupMember()
                }
            }
        }
    }

    Component {
        id: communtiyColumnComponent
        CommunityColumnView {
            communitySectionModule: root.rootStore.chatCommunitySectionModule
            communityData: sectionItemModel
            store: root.rootStore
            communitiesStore: root.communitiesStore
            walletAssetsStore: root.walletAssetsStore
            currencyStore: root.currencyStore
            emojiPopup: root.emojiPopup
            hasAddedContacts: root.hasAddedContacts
            isPendingOwnershipRequest: root.isPendingOwnershipRequest
            onInfoButtonClicked: root.communityInfoButtonClicked()
            onManageButtonClicked: root.communityManageButtonClicked()
            onFinaliseOwnershipClicked: root.finaliseOwnershipClicked()
        }
    }

    Component {
        id: statusStickerPackClickPopup
        StatusStickerPackClickPopup{
            transactionStore: root.transactionStore
            walletAssetsStore: root.walletAssetsStore
            onClosed: {
                destroy();
            }
        }
    }
}

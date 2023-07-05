﻿import QtQuick 2.14
import QtQuick.Layouts 1.14
import QtQuick.Controls 2.14

import StatusQ.Core 0.1
import StatusQ.Core.Theme 0.1
import StatusQ.Controls 0.1
import StatusQ.Components 0.1

import AppLayouts.Communities.layouts 1.0
import AppLayouts.Communities.panels 1.0

import shared.popups 1.0

import utils 1.0

StackLayout {
    id: root

    property string communityId
    property string name
    property string description
    property string introMessage
    property string outroMessage
    property string logoImageData
    property string bannerImageData
    property rect bannerCropRect
    property color color
    property string tags
    property string selectedTags
    property bool archiveSupportEnabled
    property bool requestToJoinEnabled
    property bool pinMessagesEnabled
    property string previousPageName: (currentIndex === 1) ? qsTr("Overview") : ""

    property bool editable: false
    property bool owned: false

    function navigateBack() {
        if (editSettingsPanelLoader.item.dirty)
            settingsDirtyToastMessage.notifyDirty()
        else
            root.currentIndex = 0
    }

    signal edited(Item item) // item containing edited fields (name, description, logoImagePath, color, options, etc..)

    signal inviteNewPeopleClicked
    signal airdropTokensClicked
    signal backUpClicked

    clip: true

    SettingsPage {
        title: qsTr("Overview")

        rightPadding: 64
        bottomPadding: 64

        contentItem: ColumnLayout {
            spacing: 16

            RowLayout {
                Layout.fillWidth: true

                spacing: 16

                StatusSmartIdenticon {
                    objectName: "communityOverviewSettingsPanelIdenticon"
                    name: root.name
                    asset.width: 80
                    asset.height: 80
                    asset.color: root.color
                    asset.letterSize: width / 2.4
                    asset.name: root.logoImageData
                    asset.isImage: true
                }

                ColumnLayout {
                    Layout.fillWidth: true

                    StatusBaseText {
                        id: nameText
                        objectName: "communityOverviewSettingsCommunityName"
                        Layout.fillWidth: true
                        font.pixelSize: 24
                        color: Theme.palette.directColor1
                        wrapMode: Text.WordWrap
                        text: root.name
                    }

                    StatusBaseText {
                        id: descriptionText
                        objectName: "communityOverviewSettingsCommunityDescription"
                        Layout.fillWidth: true
                        font.pixelSize: 15
                        color: Theme.palette.directColor1
                        wrapMode: Text.WordWrap
                        text: root.description
                    }
                }

                StatusButton {
                    objectName: "communityOverviewSettingsEditCommunityButton"
                    visible: root.editable
                    text: qsTr("Edit Community")
                    onClicked: root.currentIndex = 1
                }
            }

            Rectangle {
                Layout.fillWidth: true

                implicitHeight: 1
                visible: root.editable
                color: Theme.palette.statusMenu.separatorColor
            }

            RowLayout {
                Layout.fillWidth: true

                visible: root.owned

                StatusIcon {
                    icon: "info"
                    color: Theme.palette.directColor1
                }

                StatusBaseText {
                    Layout.fillWidth: true
                    text: qsTr("This node is the Community Owner Node. For your Community to function correctly try to keep this computer with Status running and online as much as possible.")
                    font.pixelSize: 15
                    color: Theme.palette.directColor1
                    wrapMode: Text.WordWrap
                }
            }

            Item {
                Layout.fillHeight: true
            }

            RowLayout {
                BannerPanel {
                    objectName: "invitePeopleBanner"
                    text: qsTr("Welcome to your community!")
                    buttonText: qsTr("Invite new people")
                    icon.name: "invite-users"
                    onButtonClicked: root.inviteNewPeopleClicked()
                }
                Item {
                   Layout.fillWidth: true
                }
                BannerPanel {
                    objectName: "airdropBanner"
                    visible: root.owned
                    text: qsTr("Try an airdrop to reward your community for engagement!")
                    buttonText: qsTr("Airdrop Tokens")
                    icon.name: "airdrop"
                    onButtonClicked: root.airdropTokensClicked()
                }

                Item {
                   Layout.fillWidth: true
                }

                BannerPanel {
                    objectName: "backUpBanner"
                    visible: root.owned
                    text: qsTr("Back up community key")
                    buttonText: qsTr("Back up")
                    icon.name: "objects"
                    onButtonClicked: root.backUpClicked()
                }
            }
        }
    }

    SettingsPage {
        id: editCommunityPage

        title: qsTr("Edit Community")

        contentItem: Loader {
            id: editSettingsPanelLoader

            function reloadContent() {
                active = false
                active = true
            }

            sourceComponent: EditSettingsPanel {
                id: editSettingsPanel

                function isValidRect(r /*rect*/) {
                    return r.width !== 0 && r.height !== 0
                }

                readonly property bool dirty:
                    root.name != name ||
                    root.description != description ||
                    root.introMessage != introMessage ||
                    root.outroMessage != outroMessage ||
                    root.archiveSupportEnabled != options.archiveSupportEnabled ||
                    root.requestToJoinEnabled != options.requestToJoinEnabled ||
                    root.pinMessagesEnabled != options.pinMessagesEnabled ||
                    root.color != color ||
                    root.selectedTags != selectedTags ||
                    root.logoImageData != logoImageData ||
                    logoImagePath.length > 0 ||
                    isValidRect(logoCropRect) ||
                    root.bannerImageData != bannerImageData ||
                    bannerPath.length > 0 ||
                    isValidRect(bannerCropRect)

                name: root.name
                description: root.description
                introMessage: root.introMessage
                outroMessage: root.outroMessage
                tags: root.tags
                selectedTags: root.selectedTags
                color: root.color
                logoImageData: root.logoImageData
                bannerImageData: root.bannerImageData

                options {
                    archiveSupportEnabled: root.archiveSupportEnabled
                    requestToJoinEnabled: root.requestToJoinEnabled
                    pinMessagesEnabled: root.pinMessagesEnabled
                }

                bottomReservedSpace:
                    Qt.size(settingsDirtyToastMessage.implicitWidth,
                            settingsDirtyToastMessage.implicitHeight +
                            settingsDirtyToastMessage.anchors.bottomMargin)

                bottomReservedSpaceActive: dirty

                Binding {
                    target: editSettingsPanel.flickable
                    property: "bottomMargin"
                    value: 24
                }
            }
        }

        SettingsDirtyToastMessage {
            id: settingsDirtyToastMessage

            z: 1
            anchors {
                bottom: parent.bottom
                horizontalCenter: parent.horizontalCenter
                bottomMargin: 16
            }

            active: !!editSettingsPanelLoader.item &&
                    editSettingsPanelLoader.item.dirty

            saveChangesButtonEnabled:
                !!editSettingsPanelLoader.item &&
                editSettingsPanelLoader.item.saveChangesButtonEnabled

            onResetChangesClicked: editSettingsPanelLoader.reloadContent()

            onSaveChangesClicked: {
                root.currentIndex = 0
                root.edited(editSettingsPanelLoader.item)
                editSettingsPanelLoader.reloadContent()
            }
        }
    }
}
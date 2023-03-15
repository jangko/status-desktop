import QtQuick 2.13
import QtQuick.Controls 2.13
import QtQuick.Layouts 1.13
import QtQml.Models 2.14
import QtGraphicalEffects 1.13

import StatusQ.Core 0.1
import StatusQ.Core.Theme 0.1
import StatusQ.Controls 0.1
import StatusQ.Components 0.1
import StatusQ.Popups 0.1
import StatusQ.Core.Utils 0.1 as StatusQUtils

import utils 1.0

import shared.panels 1.0
import shared.controls 1.0
import shared.controls.chat 1.0

import "../stores"
import "../popups"
import "../controls"
import "../../stores"

SettingsContentBase {
    id: root

    property DevicesStore devicesStore
    property ProfileStore profileStore
    property PrivacyStore privacyStore

    property bool isSyncing: false

    Component.onCompleted: {
        root.devicesStore.loadDevices()
    }

    ColumnLayout {
        width: root.contentWidth
        spacing: Style.current.padding

        QtObject {
            id: d

            /*
                Device INFO:
                    id: "abcdabcd-1234-5678-9012-12a34b5cd678",
                    identity: ""
                    version: 1
                    enabled: true
                    timestamp: 0
                    metadata:
                        name: "MacBook-1"
                        deviceType: "macosx"
                        fcmToken: ""
            */

            readonly property var instructionsModel: [
                                        qsTr("Verify your login with password or KeyCard"),
                                        qsTr("Reveal a temporary QR and Sync Code") + "*",
                                        qsTr("Share that information with your new device"),
                                    ]


            function personalizeDevice(model) {
                Global.openPopup(personalizeDevicePopup, {
                                     "deviceModel": model
                                 })
            }

            function setupSyncing() {
                const keyUid = root.profileStore.isKeycardUser ? root.profileStore.keyUid : ""
                root.devicesStore.authenticateUser(keyUid)
            }
        }


        Connections {
            target: devicesStore.devicesModule

            function onUserAuthenticated(pin, password, keyUid) {
                if (!password)
                    return
                // Authentication flow returns empty keyUid for non-keycard user.
                const effectiveKeyUid = root.profileStore.isKeycardUser
                                      ? keyUid
                                      : root.profileStore.keyUid
                Global.openPopup(setupSyncingPopup, {
                                     password,
                                     keyUid: effectiveKeyUid
                                 })
            }
        }

        StatusBaseText {
            Layout.fillWidth: true
            text: qsTr("Devices")
            font.pixelSize: 15
        }

        StatusBaseText {
            Layout.fillWidth: true
            visible: root.devicesStore.devicesModule.devicesLoading
            text: qsTr("Loading devices...")
        }

        StatusBaseText {
            Layout.fillWidth: true
            visible: root.devicesStore.devicesModule.devicesLoadingError
            text: qsTr("Error loading devices. Please try again later.")
        }

        ListView {
            id: listView
            Layout.fillWidth: true
            Layout.topMargin: 17
            Layout.bottomMargin: 17

            implicitHeight: contentHeight

            spacing: Style.current.padding
            model: root.devicesStore.devicesModel

            visible: !root.devicesStore.devicesModule.devicesLoading &&
                !root.devicesStore.devicesModule.devicesLoadingError &&
                root.devicesStore.isDeviceSetup

            delegate: StatusSyncDeviceDelegate {
                width: ListView.view.width
                deviceName: model.name
                deviceType: model.deviceType
                timestamp: model.timestamp
                isCurrentDevice: model.isCurrentDevice
                onSetupSyncingButtonClicked: {
                    d.setupSyncing(SetupSyncingPopup.GenerateSyncCode)
                }
                onClicked: {
                    d.personalizeDevice(model)
                }
            }
        }

        Rectangle {
            Layout.alignment: Qt.AlignHCenter
            Layout.topMargin: 17

            implicitWidth: instructionsLayout.implicitWidth
                           + instructionsLayout.anchors.leftMargin
                           + instructionsLayout.anchors.rightMargin

            implicitHeight: instructionsLayout.implicitHeight
                            + instructionsLayout.anchors.topMargin
                            + instructionsLayout.anchors.bottomMargin

            color: Theme.palette.primaryColor3
            radius: 8

            ColumnLayout {
                id: instructionsLayout

                anchors {
                    fill: parent
                    topMargin: 24
                    bottomMargin: 24
                    leftMargin: 16
                    rightMargin: 16
                }

                spacing: 17

                StatusBaseText {
                    Layout.fillWidth: true
                    Layout.topMargin: -8
                    horizontalAlignment: Text.AlignHCenter
                    color: Theme.palette.primaryColor1
                    font.pixelSize: 17
                    font.weight: Font.Bold
                    text: qsTr("Sync a New Device")
                }

                StatusBaseText {
                    Layout.fillWidth: true
                    horizontalAlignment: Text.AlignHCenter
                    color: Theme.palette.baseColor1
                    font.pixelSize: 15
                    font.weight: Font.Medium
                    text: qsTr("You own your data. Sync it among your devices.")
                }

                GridLayout {
                    Layout.alignment: Qt.AlignHCenter
                    rows: d.instructionsModel.length
                    flow: GridLayout.TopToBottom

                    Repeater {
                        model: d.instructionsModel

                        StatusBaseText {
                            Layout.alignment: Qt.AlignVCenter
                            color: Theme.palette.baseColor1
                            font.pixelSize: 13
                            font.weight: Font.Medium
                            text: index + 1
                        }
                    }

                    Repeater {
                        model: d.instructionsModel

                        StatusBaseText {
                            Layout.alignment: Qt.AlignVCenter
                            horizontalAlignment: Text.AlignLeft
                            color: Theme.palette.directColor1
                            font.pixelSize: 15
                            text: modelData
                        }
                    }
                }

                StatusButton {
//                    type: StatusRoundButton.Type.Secondary
                    Layout.alignment: Qt.AlignHCenter
                    normalColor: Theme.palette.primaryColor1
                    hoverColor: Theme.palette.miscColor1;
                    textColor: Theme.palette.indirectColor1
                    font.weight: Font.Medium
                    text: qsTr("Setup Syncing")
                    onClicked: {
                        d.setupSyncing()
                    }
                }

                StatusBaseText {
                    Layout.fillWidth: true
                    horizontalAlignment: Text.AlignHCenter
                    color: Theme.palette.baseColor1
                    font.pixelSize: 13
                    text: "* " + qsTr("This is best done in private. The code will grant access to your profile.")
                }
            }
        }

        StatusButton {
            id: backupBtn
            Layout.alignment: Qt.AlignHCenter
            Layout.topMargin: 17
            text: qsTr("Backup Data")
            onClicked : {
                let lastUpdate = root.privacyStore.backupData() * 1000
                console.log("Backup done at: ", LocaleUtils.formatDateTime(lastUpdate))
            }
        }

        Component {
            id: personalizeDevicePopup

            SyncDeviceCustomizationPopup {
                anchors.centerIn: parent
                devicesStore: root.devicesStore
            }
        }

        Component {
            id: setupSyncingPopup

            SetupSyncingPopup {
                anchors.centerIn: parent
                devicesStore: root.devicesStore
                profileStore: root.profileStore
            }
        }
    }
}
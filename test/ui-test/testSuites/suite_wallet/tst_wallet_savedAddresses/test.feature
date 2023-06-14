Feature: Wallet -> Saved addresses Management


Background:
    Given A first time user lands on the status desktop and generates new key
	And the user signs up with username "tester123" and password "TesTEr16843/!@00"
	And the user lands on the signed in app
    And the user opens the wallet section
    And the user accepts the signing phrase

    Scenario Outline: The user can add saved address with all network options, edit address name and delete address record
        When the user adds a saved address named "<name>" and address "<address>"
        And the user edits a saved address with name "<name>" to "<new_name>"
        Then the name "<new_name>" is in the list of saved addresses
        When the user deletes the saved address with name "<new_name>"
        Then the name "<new_name>" is not in the list of saved addresses
        Examples:
            | name | address                                    |new_name |
            | bar  | 0x8397bc3c5a60a1883174f722403d63a8833312b7 |foo      |
           # | foo  | nastya.stateofus.eth | bar | https://github.com/status-im/status-desktop/issues/11090
     # TODO: actions from burger menu
     # TODO: split the scenario above to several (exclude delete i think)
     # TODO: enhance edit actions to change networks
     # TODO: test for Share button
     # TODO: add logic to recognize mainnet / testnet and select appropriate networks
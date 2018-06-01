//
//  AppLockManager.swift
//  ownCloud
//
//  Created by Javier Gonzalez on 06/05/2018.
//  Copyright © 2018 ownCloud GmbH. All rights reserved.
//

/*
 * Copyright (C) 2018, ownCloud GmbH.
 *
 * This code is covered by the GNU Public License Version 3.
 *
 * For distribution utilizing Apple mechanisms please see https://owncloud.org/contribute/iOS-license-exception/
 * You should have received a copy of this license along with this program. If not, see <http://www.gnu.org/licenses/gpl-3.0.en.html>.
 *
 */

import UIKit
import ownCloudSDK

class AppLockManager: NSObject {

    // MARK: - Interface view mode
    enum PasscodeInterfaceMode {
        case unlockPasscode
        case unlockPasscodeError
    }

    // MARK: Keychain Keys
    let passcodeKeychainAccount = "passcode-keychain-account"
    let passcodeKeychainPath = "passcode-keychain-path"

    // MARK: Global vars

    // Common
    private var window: LockWindow?
    private var passcodeMode: PasscodeInterfaceMode?
    private var passcodeViewController: PasscodeViewController?

    // Unlock
    private var dateApplicationWillResignActive: Date?
    private var userDefaults: UserDefaults

    // Brute force protection
    public let TimesPasscodeFailedKey: String =  "times-passcode-failed"
    public let DateAllowTryPasscodeAgainKey: String =  "date-allow-try-passcode-again"
    private var timesPasscodeFailed: Int {
        didSet {
            self.userDefaults.set(timesPasscodeFailed, forKey: TimesPasscodeFailedKey)
        }
    }
    private var dateAllowTryAgain: Date? {
        didSet {
            self.userDefaults.set(NSKeyedArchiver.archivedData(withRootObject: dateAllowTryAgain as Any), forKey: DateAllowTryPasscodeAgainKey)
        }
    }
    private let timesAllowPasscodeFail: Int = 3
    private let powBaseBruteForce: Decimal = 1.5
    private var timerBruteForce: Timer?

    // Utils

    var isPasscodeStoredOnKeychain: Bool {
        return (OCAppIdentity.shared().keychain.readDataFromKeychainItem(forAccount: passcodeKeychainAccount, path: passcodeKeychainPath) != nil)
    }

    var passcodeFromKeychain: String? {
        if let passcodeData = OCAppIdentity.shared().keychain.readDataFromKeychainItem(
            forAccount: passcodeKeychainAccount, path: passcodeKeychainPath) {
            return NSKeyedUnarchiver.unarchiveObject(with: passcodeData) as? String
        } else {
            return nil
        }
    }

    private var isPasscodeActivated: Bool {
        return (self.userDefaults.bool(forKey: SecuritySettingsPasscodeKey) && self.isPasscodeStoredOnKeychain)
    }

    private var shouldBeLocked: Bool {
        var output: Bool = true

        if isPasscodeActivated {
            if let date = self.dateApplicationWillResignActive {

                let elapsedSeconds = Date().timeIntervalSince(date)
                let minSecondsToAsk = self.userDefaults.integer(forKey: SecuritySettingsFrequencyKey)

                if Int(elapsedSeconds) < minSecondsToAsk {
                    output = false
                }
            }
        } else {
            output = false
        }

        return output
    }

    // MARK: - Init

    static var shared = AppLockManager()

    public override init() {
        // TODO: Use OCAppIdentity-provided user defaults in the future
        self.userDefaults = UserDefaults(suiteName: OCAppIdentity.shared().appGroupIdentifier) ?? UserDefaults.standard

        // Brute Force protection
        self.timesPasscodeFailed = self.userDefaults.integer(forKey: TimesPasscodeFailedKey)
        if let data = self.userDefaults.data(forKey: DateAllowTryPasscodeAgainKey) {
            self.dateAllowTryAgain = NSKeyedUnarchiver.unarchiveObject(with: data) as? Date
        }

        super.init()
    }

    // MARK: - Show Passcode View

    func showPasscodeIfNeeded() {

        if isPasscodeActivated {
            if self.passcodeViewController == nil {

                self.prepareLockScreen()

                // Brute force protection
                if let date = self.dateAllowTryAgain, date > Date() {
                    //User killed the app
                    self.passcodeMode = .unlockPasscodeError
                    self.passcodeViewController?.enableKeyboardButtons(enabled: false)
                    self.scheduledTimerToUpdateInterfaceTime()
                } else {
                    self.passcodeMode = .unlockPasscode
                }

                self.updateUI()

            }
        }
    }

    func prepareLockScreen() {

        let passcodeCompleteHandler:PasscodeCompleteHandler = {
            (passcode: String) in
            self.passcodeComplete(passcode: passcode)
        }

        self.passcodeViewController = PasscodeViewController(cancelHandler: {}, passcodeCompleteHandler: passcodeCompleteHandler)

        self.window = LockWindow(frame: UIScreen.main.bounds)
        self.window?.windowLevel = UIWindowLevelStatusBar
        self.window?.rootViewController = self.passcodeViewController!
        self.window?.makeKeyAndVisible()
    }

    func applicationWillResignActive() {

        //Store the date when the app will be resign
        if self.isPasscodeActivated,
            self.dateApplicationWillResignActive == nil,
            self.passcodeViewController == nil || self.passcodeMode != .unlockPasscode,
            self.passcodeViewController == nil || self.passcodeMode != .unlockPasscodeError {
            self.dateApplicationWillResignActive = Date()
        }

        //Show the passcode
        self.showPasscodeIfNeeded()
    }

    // MARK: - Interface updates

    private func updateUI() {

        var messageText : String?
        var errorText : String? = nil

        switch self.passcodeMode {

        case .unlockPasscode?:
            messageText = "Enter code".localized
            self.passcodeViewController?.cancelButton?.isHidden = true

        case .unlockPasscodeError?:
            messageText = "Enter code".localized
            errorText = "Incorrect code".localized
            self.passcodeViewController?.cancelButton?.isHidden = true

        default:
            break
        }

        self.passcodeViewController?.updateUI(
            message: messageText,
            errorMessage: errorText,
            timeoutMessage: nil,
            passcode: nil)
    }

    func dismissAskedPasscodeIfDateToAskIsLower() {
        if !shouldBeLocked {
            if self.passcodeViewController != nil {
                //Protection to hide the PasscodeViewController only if is in unlock mode
                if self.passcodeMode == .unlockPasscode ||
                    self.passcodeMode == .unlockPasscodeError {
                    self.dismissPasscode(animated: true)
                    self.dateApplicationWillResignActive = nil
                }
            }
        }
    }

    func dismissPasscode(animated:Bool) {

        let hideWindow = {
            self.window?.isHidden = true
            self.passcodeViewController = nil
            self.window = nil
        }

        if animated {
            self.window?.hideWindowAnimation {
                hideWindow()
            }
        } else {
            hideWindow()
        }
    }

    // MARK: - Passcode Write/Remove
    func writePasscodeInKeychain(passcode: String) {
        OCAppIdentity.shared().keychain.write(NSKeyedArchiver.archivedData(withRootObject: passcode), toKeychainItemForAccount: passcodeKeychainAccount, path: passcodeKeychainPath)
    }

    func removePasscodeFromKeychain() {
        OCAppIdentity.shared().keychain.removeItem(forAccount: passcodeKeychainAccount, path: passcodeKeychainPath)
    }

    // MARK: - Brute force protection

    private func scheduledTimerToUpdateInterfaceTime() {

        self.updatePasscodeInterfaceTime()
        self.timerBruteForce = Timer.scheduledTimer(timeInterval: 1, target: self, selector: #selector(self.updatePasscodeInterfaceTime), userInfo: nil, repeats: true)
    }

    @objc private func updatePasscodeInterfaceTime() {

        if let date = self.dateAllowTryAgain {
            let interval = Int(date.timeIntervalSinceNow)
            let seconds = interval % 60
            let minutes = (interval / 60) % 60
            let hours = (interval / 3600)

            let dateFormatted:String?
            if hours > 0 {
                dateFormatted = String(format: "%02d:%02d:%02d", hours, minutes, seconds)
            } else {
                dateFormatted = String(format: "%02d:%02d", minutes, seconds)
            }

            let timeoutMessage:String = NSString(format: "Please try again within %@".localized as NSString, dateFormatted!) as String
            self.passcodeViewController?.updateTimeoutMessage(timeoutMessage: timeoutMessage)

            if date <= Date() {
                //Time elapsed, allow enter passcode again
                self.timerBruteForce?.invalidate()
                self.passcodeViewController?.enableKeyboardButtons(enabled: true)
                self.updateUI()
            }
        }
    }

    private func secondsToTryAgain() -> Int {
        let powValue = pow(powBaseBruteForce, timesPasscodeFailed)
        return Int(truncating: NSDecimalNumber(decimal: powValue))
    }

    // MARK: - Logic

    func passcodeComplete(passcode: String) {
        if passcode == self.passcodeFromKeychain {
            self.dateApplicationWillResignActive = nil
            self.timesPasscodeFailed = 0
            self.dismissPasscode(animated: true)
        } else {
            self.passcodeViewController?.errorMessageLabel?.shakeHorizontally()
            self.passcodeMode = .unlockPasscodeError
            self.updateUI()

            // Brute force protection
            self.timesPasscodeFailed += 1
            if self.timesPasscodeFailed >= self.timesAllowPasscodeFail {
                self.passcodeViewController?.enableKeyboardButtons(enabled: false)
                self.dateAllowTryAgain = Date().addingTimeInterval(TimeInterval(self.secondsToTryAgain()))
                self.scheduledTimerToUpdateInterfaceTime()
            }
        }
    }
}

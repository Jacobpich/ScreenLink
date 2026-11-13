import UIKit

enum Keysym {
    static let backspace: UInt32 = 0xFF08
    static let tab: UInt32 = 0xFF09
    static let returnKey: UInt32 = 0xFF0D
    static let escape: UInt32 = 0xFF1B
    static let delete: UInt32 = 0xFFFF
    static let home: UInt32 = 0xFF50
    static let left: UInt32 = 0xFF51
    static let up: UInt32 = 0xFF52
    static let right: UInt32 = 0xFF53
    static let down: UInt32 = 0xFF54
    static let pageUp: UInt32 = 0xFF55
    static let pageDown: UInt32 = 0xFF56
    static let end: UInt32 = 0xFF57
    static let f1: UInt32 = 0xFFBE
    static let shift: UInt32 = 0xFFE1
    static let control: UInt32 = 0xFFE3
    static let capsLock: UInt32 = 0xFFE5
    static let metaL: UInt32 = 0xFFE7
    static let option: UInt32 = 0xFFE9   // Alt_L → Option on macOS
    static let superL: UInt32 = 0xFFEB
    static let space: UInt32 = 0x0020

    /// The keysym the Mac treats as ⌘. Apple's server maps Meta_L to Command;
    /// some setups prefer Super_L, so this is user-configurable.
    static var command: UInt32 {
        UserDefaults.standard.bool(forKey: "commandSendsSuper") ? superL : metaL
    }

    static func function(_ n: Int) -> UInt32 { f1 + UInt32(n - 1) }

    /// Characters on a US layout that need Shift held.
    private static let shifted: Set<Character> = Set("~!@#$%^&*()_+{}|:\"<>?")

    /// Keysym for a typed character, and whether Shift must be held.
    static func forCharacter(_ ch: Character) -> (UInt32, Bool)? {
        switch ch {
        case "\n", "\r": return (returnKey, false)
        case "\t": return (tab, false)
        case "\u{8}": return (backspace, false)
        default: break
        }
        guard let scalar = ch.unicodeScalars.first else { return nil }
        let v = scalar.value
        let needsShift = ch.isUppercase || shifted.contains(ch)
        if v >= 0x20 && v <= 0x7E { return (v, needsShift) }
        if v >= 0xA0 && v <= 0xFF { return (v, needsShift) }
        // Map common "smart" punctuation back to ASCII.
        switch ch {
        case "‘", "’": return (0x27, false)
        case "“", "”": return (0x22, true)
        case "–", "—": return (0x2D, false)
        case "…": return nil
        default: return (0x0100_0000 | v, false)
        }
    }

    /// Hardware keyboard (UIKey) → keysym.
    static func forKey(_ key: UIKey) -> UInt32? {
        switch key.keyCode {
        case .keyboardReturnOrEnter, .keypadEnter: return returnKey
        case .keyboardEscape: return escape
        case .keyboardDeleteOrBackspace: return backspace
        case .keyboardDeleteForward: return delete
        case .keyboardTab: return tab
        case .keyboardSpacebar: return space
        case .keyboardLeftArrow: return left
        case .keyboardRightArrow: return right
        case .keyboardUpArrow: return up
        case .keyboardDownArrow: return down
        case .keyboardHome: return home
        case .keyboardEnd: return end
        case .keyboardPageUp: return pageUp
        case .keyboardPageDown: return pageDown
        case .keyboardLeftShift, .keyboardRightShift: return shift
        case .keyboardLeftControl, .keyboardRightControl: return control
        case .keyboardLeftAlt, .keyboardRightAlt: return option
        case .keyboardLeftGUI, .keyboardRightGUI: return command
        case .keyboardCapsLock: return capsLock
        case .keyboardF1: return function(1)
        case .keyboardF2: return function(2)
        case .keyboardF3: return function(3)
        case .keyboardF4: return function(4)
        case .keyboardF5: return function(5)
        case .keyboardF6: return function(6)
        case .keyboardF7: return function(7)
        case .keyboardF8: return function(8)
        case .keyboardF9: return function(9)
        case .keyboardF10: return function(10)
        case .keyboardF11: return function(11)
        case .keyboardF12: return function(12)
        default: break
        }
        let chars = key.charactersIgnoringModifiers
        guard let ch = chars.first, chars.count == 1 else { return nil }
        // With Shift held, use the shifted character so the Mac sees e.g. "A" or "!".
        if key.modifierFlags.contains(.shift), let shiftedCh = key.characters.first,
           !key.modifierFlags.contains(.command), !key.modifierFlags.contains(.control),
           let (sym, _) = forCharacter(shiftedCh) {
            return sym
        }
        return forCharacter(Character(ch.lowercased()))?.0
    }
}

import Foundation

public extension Data {
    /// Initialize Data from a hex string (handles "0x" prefix automatically)
    init?(hex: String) {
        // 1. Sanitize: Remove "0x" if present
        let cleanHex = hex.hasPrefix("0x") ? String(hex.dropFirst(2)) : hex
        
        // 2. Standard Hex Parsing
        let len = cleanHex.count / 2
        var data = Data(capacity: len)
        var ptr = cleanHex.startIndex
        
        for _ in 0..<len {
            let end = cleanHex.index(ptr, offsetBy: 2)
            let bytes = cleanHex[ptr..<end]
            if let num = UInt8(bytes, radix: 16) {
                data.append(num)
            } else {
                return nil
            }
            ptr = end
        }
        self = data
    }
    
    /// Convert Data back to Hex String
    var hexString: String {
        return map { String(format: "%02x", $0) }.joined()
    }
}


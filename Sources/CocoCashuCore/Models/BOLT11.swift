import Foundation

/// Lightweight BOLT11 invoice helpers.
///
/// This intentionally decodes ONLY the human-readable amount prefix
/// (`ln<network><amount><multiplier>1<data>`), in integer math — it does not
/// validate the bech32 checksum or signature. That is safe for this wallet
/// because the client-side amount is a UI preview: `MintService.spend` verifies
/// it against the mint's melt quote (the mint decodes the invoice
/// authoritatively) and aborts on mismatch.
public enum BOLT11 {
    /// Extract the invoice amount in whole satoshis, or nil when the invoice has
    /// no amount, the amount is not a whole number of sats (Cashu has no
    /// millisats — reject rather than round), or the string isn't an invoice.
    public static func amountSats(from invoice: String) -> Int64? {
        let lower = invoice.lowercased()
        guard lower.hasPrefix("ln") else { return nil }

        // ln + network letters + digits + multiplier, followed by the bech32 '1'
        // separator. Requiring the separator prevents misreading an AMOUNTLESS
        // invoice (`lnbc1<data>`) whose data happens to start with a multiplier
        // letter as "1 milli-BTC".
        let pattern = "^ln[a-z]+?(\\d+)([pnum])(?=1)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }

        let range = NSRange(location: 0, length: lower.utf16.count)
        guard let match = regex.firstMatch(in: lower, range: range),
              let r1 = Range(match.range(at: 1), in: lower),
              let r2 = Range(match.range(at: 2), in: lower),
              let value = Int64(lower[r1]), value > 0 else { return nil }

        // 1 BTC = 100,000,000 sats. Integer math only: Double arithmetic here
        // silently truncated fractional-sat invoices (lnbc105n = 10.5 sats read
        // as 10), making the app display an amount the invoice doesn't say.
        switch String(lower[r2]) {
        case "m":                                // milli-BTC = 100,000 sats
            let (sats, overflow) = value.multipliedReportingOverflow(by: 100_000)
            return overflow ? nil : sats
        case "u":                                // micro-BTC = 100 sats
            let (sats, overflow) = value.multipliedReportingOverflow(by: 100)
            return overflow ? nil : sats
        case "n":                                // nano-BTC = 0.1 sat
            guard value % 10 == 0 else { return nil }
            return value / 10
        case "p":                                // pico-BTC = 0.0001 sat
            guard value % 10_000 == 0 else { return nil }
            return value / 10_000
        default:
            return nil
        }
    }
}

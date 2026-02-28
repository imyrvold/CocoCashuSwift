
import Foundation
import CocoCashuCore

public struct RealMintAPI: MintAPI, Sendable {
    public let baseURL: URL
    private let session: URLSession
    
    public init(baseURL: URL, session: URLSession? = nil) {
        self.baseURL = baseURL
        
        if let s = session {
            self.session = s
        } else {
            // Create a custom config that fails fast instead of retrying
            let config = URLSessionConfiguration.default
            config.waitsForConnectivity = false // CRITICAL: Prevents auto-retries on network switch
            config.timeoutIntervalForRequest = 30
            config.timeoutIntervalForResource = 300
            self.session = URLSession(configuration: config)
        }
    }
    
    // MARK: - Tolerant response models
    struct InfoResponse: Decodable { let name: String? }
    
    struct QuoteResponse: Decodable {
        let invoice: String
        let expiresAt: Date?
        let quoteId: String?
        
        enum CodingKeys: String, CodingKey {
            case invoice, expiresAt = "expires_at", quoteId
            // Alternate keys used by some mints
            case request, pr, quote, id, quote_id = "quote_id"
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            // invoice candidates
            if let inv = try c.decodeIfPresent(String.self, forKey: .invoice) {
                invoice = inv
            } else if let inv = try c.decodeIfPresent(String.self, forKey: .request) {
                invoice = inv
            } else if let inv = try c.decodeIfPresent(String.self, forKey: .pr) {
                invoice = inv
            } else {
                throw DecodingError.keyNotFound(CodingKeys.invoice, .init(codingPath: decoder.codingPath, debugDescription: "No invoice field in quote response"))
            }
            // expires
            expiresAt = try c.decodeIfPresent(Date.self, forKey: .expiresAt)
            // quote id candidates (decode stepwise and tolerate numeric ids)
            let q1 = try? c.decodeIfPresent(String.self, forKey: .quoteId)
            let q2 = try? c.decodeIfPresent(String.self, forKey: .quote)
            let q3 = try? c.decodeIfPresent(String.self, forKey: .id)
            var q4: String? = nil
            if let s = try? c.decodeIfPresent(String.self, forKey: .quote_id) {
                q4 = s
            } else if let n = try? c.decodeIfPresent(Int.self, forKey: .quote_id) {
                q4 = String(n)
            }
            quoteId = q1 ?? q2 ?? q3 ?? q4
        }
    }
    
    struct StatusResponse: Decodable { public let paid: Bool }
    
    struct MintTokenResponse: Decodable {
        struct MintProof: Decodable {
            let amount: Int64
            let secret: String
            let C: String
            let id: String? // Keyset ID (usually present)
        }
        
        public let proofs: [MintProof]
        let rawTokenString: String?
        
        private enum CodingKeys: String, CodingKey { case proofs, token, tokens }
        
        private struct TokenObject: Decodable { let proofs: [MintProof]? }
        private struct TokenEntry: Decodable { let mint: String?; let proofs: [MintProof] }
        
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            if let direct = try c.decodeIfPresent([MintProof].self, forKey: .proofs) {
                self.proofs = direct; self.rawTokenString = nil; return
            }
            if c.contains(.token) {
                if let obj = try? c.decode(TokenObject.self, forKey: .token), let p = obj.proofs {
                    self.proofs = p; self.rawTokenString = nil; return
                }
                if let arr = try? c.decode([TokenEntry].self, forKey: .token), let first = arr.first {
                    self.proofs = first.proofs; self.rawTokenString = nil; return
                }
                if let tokenString = try? c.decode(String.self, forKey: .token) { // cashuA... string
                    self.proofs = []; self.rawTokenString = tokenString; return
                }
            }
            if let arr = try? c.decode([TokenEntry].self, forKey: .tokens), let first = arr.first {
                self.proofs = first.proofs; self.rawTokenString = nil; return
            }
            throw DecodingError.keyNotFound(CodingKeys.proofs, .init(codingPath: decoder.codingPath, debugDescription: "No proofs in response"))
        }
    }
    
    struct MeltQuoteResponse: Decodable {
        let quote: String?
        let id: String?
        let quoteId: String?
        let amount: Int64?
        let feeReserve: Int64?
        
        enum CodingKeys: String, CodingKey {
            case quote
            case id
            case quoteId = "quote_id"
            case amount
            case feeReserve = "fee_reserve"
        }
    }
    
    struct MeltResponse: Decodable {
        let paid: Bool
        let preimage: String?
        let change: [ChangeSig]?
        
        // Helper struct representing the Mint's change response (NUT-05)
        struct ChangeSig: Decodable {
            let amount: Int64
            let C: String?
            let C_: String? // Some mints use C, some C_
            let id: String?
        }
        
        private enum CodingKeys: String, CodingKey {
            case paid
            case preimage              // some mints use this
            case payment_preimage      // cashu v1 uses this
            case change
        }
        
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            paid = (try? c.decode(Bool.self, forKey: .paid)) ?? false
            
            if let p = try? c.decode(String.self, forKey: .preimage) {
                preimage = p
            } else if let p = try? c.decode(String.self, forKey: .payment_preimage) {
                preimage = p
            } else {
                preimage = nil
            }
            
            if c.contains(.change) {
                do {
                    change = try c.decode([ChangeSig].self, forKey: .change)
                } catch {
                    print("❌ DECODING ERROR for 'change': \(error)")
                    change = nil
                }
            } else {
                change = nil
            }
        }
    }
    
    // MARK: - MintAPI
    
    public func requestMintQuote(mint: MintURL, amount: Int64) async throws -> (invoice: String, expiresAt: Date?, quoteId: String?) {
        let _ : InfoResponse = try await getJSON(InfoResponse.self, path: "/v1/info")
        
        do {
            let q: QuoteResponse = try await postJSON(QuoteResponse.self,
                                                      path: "/v1/mint/quote/bolt11",
                                                      body: ["amount": amount, "unit": "sat"])
            return (q.invoice, q.expiresAt, q.quoteId)
        } catch {
            print("RealMintAPI POST quote error:", error)
            throw error
        }
    }
    
    public func checkQuoteStatus(mint: MintURL, invoice: String) async throws -> QuoteStatus {
        // Common: GET /v1/mint/quote/bolt11/status?invoice=...
        do {
            let s: StatusResponse = try await getJSON(StatusResponse.self, path: "/v1/mint/quote/bolt11/status", query: ["invoice": invoice])
            return s.paid ? .paid : .pending
        } catch {
            print("RealMintAPI status check error:", error)
            throw error
        }
    }
    
    public func checkQuoteStatus(quoteId: String) async throws -> QuoteStatus {
        do {
            let s: StatusResponse = try await getJSON(
                StatusResponse.self,
                path: "/v1/mint/quote/bolt11/\(quoteId)"
            )
            return s.paid ? .paid : .pending
        } catch {
            do {
                let s: StatusResponse = try await getJSON(
                    StatusResponse.self,
                    path: "/v1/mint/quote/\(quoteId)/bolt11"
                )
                return s.paid ? .paid : .pending
            } catch {
                do {
                    let s: StatusResponse = try await getJSON(
                        StatusResponse.self,
                        path: "/v1/mint/quote/bolt11/status/\(quoteId)"
                    )
                    return s.paid ? .paid : .pending
                } catch {
                    throw CashuError.network("Could not check status for quote id \(quoteId): \(error)")
                }
            }
        }
    }
    
    public func requestTokens(mint: MintURL, for invoice: String) async throws -> [Proof] {
        do {
            let r: MintTokenResponse = try await postJSON(MintTokenResponse.self, path: "/v1/mint", body: ["invoice": invoice])
            return r.proofs.map { Proof(amount: $0.amount, mint: mint, secret: Data(hex: $0.secret) ?? Data(), C: $0.C, keysetId: $0.id ?? "") }
        } catch {
            do {
                let r2: MintTokenResponse = try await postJSON(MintTokenResponse.self, path: "/v1/mint", body: ["payment_request": invoice])
                return r2.proofs.map { Proof(amount: $0.amount, mint: mint, secret: Data(hex: $0.secret) ?? Data(), C: $0.C, keysetId: $0.id ?? "") }
            } catch {
                throw error
            }
        }
    }
    
    
    // Note: We pass the full blindedMessages here because we need the 'secret' and 'r'
    // stored inside them to construct the final Proofs after the network call returns.
    // In RealMintAPI.swift

    // Update return type to [String] (List of hex signatures)
    // In RealMintAPI.swift

    // In RealMintAPI.swift

    public func requestTokens(quoteId: String, blindedMessages: [BlindedOutput], mint: MintURL) async throws -> [BlindSignatureDTO] {
        
        // 1. Prepare Payload
        let outputsPayload = blindedMessages.map {
            [
                "amount": $0.amount,
                "B_": $0.B_,
                "id": $0.id
            ]
        }
        
        let body: [String: Any] = [
            "quote": quoteId,
            "outputs": outputsPayload
        ]
        
        // 2. Request
        let r: MintingResponse = try await postJSON(MintingResponse.self, path: "/v1/mint/bolt11", body: body)
        
        // 3. Validation
        guard r.signatures.count == blindedMessages.count else {
            throw CashuError.network("Mint returned mismatched number of signatures.")
        }
        
        // 4. Map to DTO
        return r.signatures.map { signature in
            BlindSignatureDTO(
                amount: signature.amount,
                C_: signature.C_,
                // FIX: Pass the ID from the mint response
                // This ensures unblind() uses the correct keyset ID (00b4ec...)
                id: signature.id
            )
        }
    }
    
    public func requestMeltQuote(mint: MintURL, amount: Int64, destination: String) async throws -> (quoteId: String, feeReserve: Int64) {
        let quoteBody: [String: Any] = ["request": destination, "unit": "sat"]
        let q: MeltQuoteResponse = try await postJSON(MeltQuoteResponse.self, path: "/v1/melt/quote/bolt11", anyBody: quoteBody)
        
        guard let qid = q.quote ?? q.quoteId ?? q.id else {
            throw CashuError.protocolError("Melt quote missing ID")
        }
        return (qid, q.feeReserve ?? 0)
    }
    
    public func executeMelt(mint: MintURL, quoteId: String, inputs: [Proof], outputs: [BlindedOutput]) async throws -> (preimage: String, change: [BlindSignatureDTO]?) {
        let inputDTOs: [[String: Any]] = inputs.map {
            let finalSecret: String
            if let utf8Str = String(data: $0.secret, encoding: .utf8), !utf8Str.isEmpty {
                finalSecret = utf8Str
            } else {
                finalSecret = $0.secret.base64EncodedString()
            }
            return ["id": $0.keysetId, "amount": $0.amount, "secret": finalSecret, "C": $0.C]
        }
        let outputDTOs: [[String: Any]] = outputs.map {
            ["id": $0.id, "amount": $0.amount, "B_": $0.B_]
        }
        
        let payload: [String: Any] = [
            "quote": quoteId,
            "inputs": inputDTOs,
            "outputs": outputDTOs
        ]
        
        let r: MeltResponse = try await postJSON(MeltResponse.self, path: "/v1/melt/bolt11", anyBody: payload)
        
        guard r.paid, let pre = r.preimage else {
            throw CashuError.protocolError("Melt not paid")
        }
        
        // Map change output (Blind Signatures)
        let changeSigs: [BlindSignatureDTO]? = r.change?.map { mp in
            // For change, mint returns signatures C/C_, not full proofs with secrets
            BlindSignatureDTO(amount: mp.amount, C_: mp.C_ ?? mp.C, C: mp.C_ ?? mp.C)
        }
        
        return (pre, changeSigs)
    }
    
    // MARK: - Networking helpers
    
    private func makeURL(path: String, query: [String: String]? = nil) -> URL {
        var comps = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if let query { comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        return comps.url!
    }
    
    private func getJSON<T: Decodable>(_ type: T.Type, path: String, query: [String: String]? = nil) async throws -> T {
        let url = makeURL(path: path, query: query)
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        
        req.timeoutInterval = 120
        
        let (data, resp) = try await session.data(for: req)
        try ensureOK(resp, url: url, data: data)
        return try decodeJSON(T.self, data: data)
    }
    
    private func postJSON<T: Decodable>(_ type: T.Type, path: String, body: [String: Any]) async throws -> T {
        try await postJSON(type, path: path, anyBody: body)
    }
    
    private func postJSON<T: Decodable>(_ type: T.Type, path: String, anyBody: [String: Any]) async throws -> T {
        let url = makeURL(path: path)
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        
        // FIX: Increase timeout to 120s for Lightning payments
        req.timeoutInterval = 120
        
        req.httpBody = try JSONSerialization.data(withJSONObject: anyBody, options: [])
        let (data, resp) = try await session.data(for: req)
        try ensureOK(resp, url: url, data: data)
        
        return try decodeJSON(T.self, data: data)
    }
    
    private func ensureOK(_ resp: URLResponse, url: URL, data: Data) throws {
        guard let http = resp as? HTTPURLResponse else {
            throw CashuError.network("No HTTPURLResponse for \(url)")
        }
        guard (200..<300).contains(http.statusCode) else {
            let msg = HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            let body = String(data: data, encoding: .utf8) ?? "<binary>"
            let snippet = body.prefix(280)
            throw CashuError.network("HTTP \(http.statusCode) (\(msg)) for \(url) — body: \(snippet)")
        }
    }
    
    private func decodeJSON<T: Decodable>(_ type: T.Type, data: Data) throws -> T {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try dec.decode(T.self, from: data)
    }
    
    private func getRaw(path: String, query: [String: String]? = nil) async throws -> Data {
        let url = makeURL(path: path, query: query)
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, resp) = try await session.data(for: req)
        try ensureOK(resp, url: url, data: data)
        return data
    }
    
    // Parse a string token like "cashuA..." into proofs
    private func parseCashuTokenString(_ token: String, mintURL: MintURL) -> [Proof]? {
        // Expect prefix "cashu" + version (e.g., 'A') followed by base64url payload
        guard token.lowercased().hasPrefix("cashu"), token.count > 6 else { return nil }
        let idx = token.index(token.startIndex, offsetBy: 6) // skip "cashu" + version char
        let b64url = String(token[idx...])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padded: String = {
            let rem = b64url.count % 4
            return rem == 0 ? b64url : b64url + String(repeating: "=", count: 4 - rem)
        }()
        guard let data = Data(base64Encoded: padded) else { return nil }
        struct TokenRoot: Decodable {
            struct Entry: Decodable {
                let mint: String?
                let proofs: [MintTokenResponse.MintProof] }
            let token: [Entry]
        }
        guard let root = try? JSONDecoder().decode(TokenRoot.self, from: data), let first = root.token.first else { return nil }
        return first.proofs.map {
                Proof(
                    amount: $0.amount,
                    mint: mintURL,
                    // FIX: Treat secret as UTF8 String, NOT Hex.
                    secret: $0.secret.data(using: .utf8) ?? Data(),
                    C: $0.C,
                    keysetId: $0.id ?? ""
                )
            }
    }
    
    // Models for NUT-04 execution
    public struct BlindedMessageDTO: Encodable {
        let amount: Int64
        let B_: String   // blinded message
        public init(amount: Int64, B_: String) {
            self.amount = amount
            self.B_ = B_
        }
    }
    
    private struct MintExecRequest: Encodable {
        let quote: String
        let outputs: [BlindedMessageDTO]
    }
    
    public struct MintExecResponse: Decodable {
        // NUT-04 calls these "signatures"; some older mints say "promises"
        public struct BlindSig: Decodable { let amount: Int64; let C_: String?; let C: String? }
        
        let signatures: [BlindSig]?
        let promises: [BlindSig]?
        
        var all: [BlindSig] { signatures ?? promises ?? [] }
    }
    
    // MARK: - Keys (NUT-01) for blinding
    
    struct KeysResponse: Decodable {
        struct KeysetEntry: Decodable {
            let id: String?
            let keys: [String:String]
            let input_fee_ppk: Int64?
        }
        let keys: [String:String]?
        let keysets: [KeysetEntry]?
    }
    
    // NUT-02: Response from /v1/keysets endpoint (keyset info with fees)
    struct KeysetsInfoResponse: Decodable {
        struct KeysetInfo: Decodable {
            let id: String
            let unit: String?
            let active: Bool?
            let input_fee_ppk: Int64?
        }
        let keysets: [KeysetInfo]
    }
    
    // Convert whatever the mint gives us into Keyset(amount:Int64 -> pubkeyHex)
    public func fetchKeyset() async throws -> Keyset {
        // First try to get fee info from /v1/keysets
        let feeInfo = try? await fetchKeysetFeeInfo()
        
        let r: KeysResponse = try await getJSON(KeysResponse.self, path: "/v1/keys")
        if let ks = r.keysets?.first {
            let raw = ks.keys
            var map: [Int64:String] = [:]
            for (k,v) in raw { if let a = Int64(k) { map[a] = v } }
            let keysetId = ks.id ?? baseURL.absoluteString
            let fee = ks.input_fee_ppk ?? feeInfo?[keysetId] ?? 0
            return Keyset(id: keysetId, keys: map, inputFeePPK: fee)
        }
        if let raw = r.keys {
            var map: [Int64:String] = [:]
            for (k,v) in raw { if let a = Int64(k) { map[a] = v } }
            let fee = feeInfo?.values.first ?? 0
            return Keyset(id: baseURL.absoluteString, keys: map, inputFeePPK: fee)
        }
        // Some mints expose { "1": "02ab...", "2": "03cd...", ... } at the top level
        if let obj = try? await getRaw(path: "/v1/keys"),
           let top = try? JSONSerialization.jsonObject(with: obj) as? [String:Any] {
            var map: [Int64:String] = [:]
            for (k,v) in top { if let a = Int64(k), let s = v as? String { map[a] = s } }
            if !map.isEmpty {
                let fee = feeInfo?.values.first ?? 0
                return Keyset(id: baseURL.absoluteString, keys: map, inputFeePPK: fee)
            }
        }
        throw CashuError.protocolError("Mint /v1/keys did not contain a usable keyset")
    }
    
    /// Fetch keyset fee info from /v1/keysets (NUT-02)
    public func fetchKeysetFeeInfo() async throws -> [String: Int64] {
        let r: KeysetsInfoResponse = try await getJSON(KeysetsInfoResponse.self, path: "/v1/keysets")
        var feeMap: [String: Int64] = [:]
        for ks in r.keysets {
            feeMap[ks.id] = ks.input_fee_ppk ?? 0
        }
        return feeMap
    }
    
    /// Check the fee for a specific number of inputs at this mint
    public func checkFees(forInputCount numInputs: Int) async throws -> Int64 {
        let keyset = try await fetchKeyset()
        return keyset.calculateFee(forInputCount: numInputs)
    }
    
    public func fetchKeyset(mint: URL) async throws -> Keyset {
        let tempApi = RealMintAPI(baseURL: mint)
        return try await tempApi.fetchKeyset()
    }
    
    /// Execute a PAID mint quote by submitting blinded outputs.
    /// Returns the raw blind signatures; you must unblind to create Proofs.
    private func executeMint(quoteId: String, outputs: [BlindedMessageDTO]) async throws -> [BlindSignatureDTO] {
        // Cashu.cz requires the keyset id as `id` on each output
        let keyset = try await fetchKeyset()
        let kid = keyset.id
        let path = "/v1/mint/bolt11"
        let payload: [String: Any] = [
            "quote": quoteId,
            "outputs": outputs.map { out in
                [
                    "id": kid,              // <-- keyset id, same for all outputs
                    "amount": out.amount,
                    "B_": out.B_
                ]
            }
        ]
        struct MintExecResponse: Decodable {
            struct BlindSig: Decodable {
                let id: String?
                let amount: Int64
                let C_: String
                // let dleq: ... (if present)
            }
            let signatures: [BlindSig]
        }
        
        let response: MintExecResponse = try await postJSON(MintExecResponse.self,
                                                            path: path,
                                                            anyBody: payload)
        return response.signatures.map { sig in
            BlindSignatureDTO(amount: sig.amount, C_: sig.C_, C: nil)
        }
    }
    
    public func swap(mint: MintURL, inputs: [Proof], outputs: [BlindedOutput]) async throws -> [BlindSignatureDTO] {
        // 1. Prepare Inputs
        let inputDTOs: [[String: Any]] = inputs.map {
            let finalSecret: String
            if let utf8Str = String(data: $0.secret, encoding: .utf8), !utf8Str.isEmpty {
                finalSecret = utf8Str
            } else {
                // Attempt 2: If it's raw binary (not text), encode it to Base64
                finalSecret = $0.secret.base64EncodedString()
            }
            
            return ["id": $0.keysetId, "amount": $0.amount, "secret": finalSecret, "C": $0.C]
        }

        // 2. Prepare Outputs
        let outputDTOs: [[String: Any]] = outputs.map {
            ["amount": $0.amount, "B_": $0.B_, "id": $0.id]
        }

        let payload: [String: Any] = [
            "inputs": inputDTOs,
            "outputs": outputDTOs
        ]

        struct PrivateSwapResponse: Decodable {
            struct PrivateSignature: Decodable {
                let amount: Int64
                let C_: String?
                let C: String?
                let id: String?
            }
            
            let signatures: [PrivateSignature]?
            let promises: [PrivateSignature]?
            var all: [PrivateSignature] { signatures ?? promises ?? [] }
        }
        
        let r: PrivateSwapResponse = try await postJSON(PrivateSwapResponse.self, path: "/v1/swap", anyBody: payload)

        if r.all.isEmpty {
            throw CashuError.protocolError("Swap returned no signatures")
        }
        
        // --- FIX IS HERE ---
        // We must pass '$0.id' to the new struct so 'unblind' receives it.
        return r.all.map { sig in
            let blindSignatureDTO = BlindSignatureDTO(
                amount: sig.amount,
                C_: sig.C_ ?? sig.C,
                id: sig.id
            )
            return blindSignatureDTO
        }
    }
    
    /// Public helper to execute the minting step manually (NUT-04)
    /// Used by MintCoordinator's fallback flow.
    // In RealMintAPI.swift
    
    /// Public helper to execute the minting step (NUT-04)
    public func mint(quoteId: String, outputs: [BlindedOutput]) async throws -> [BlindSignatureDTO] {
        let keyset = try await fetchKeyset()
        
        let payload: [String: Any] = [
            "quote": quoteId,
            "outputs": outputs.map { out in
                ["id": keyset.id, "amount": out.amount, "B_": out.B_]
            }
        ]
        
        // 1. Define Internal Structure for Decoding
        struct MintResponse: Decodable {
            struct BlindSig: Decodable {
                let amount: Int64
                let C_: String
            }
            let signatures: [BlindSig]
        }
        
        // 2. Request & Decode Internal Structure
        let response = try await postJSON(MintResponse.self, path: "/v1/mint/bolt11", anyBody: payload)
        
        // 3. CRITICAL FIX: Convert Internal 'BlindSig' -> Public 'BlindSignatureDTO'
        return response.signatures.map { sig in
            BlindSignatureDTO(amount: sig.amount, C_: sig.C_, C: nil)
        }
    }

    public func restore(mint: URL, outputs: [BlindedOutput]) async throws -> [BlindSignatureDTO] {
        // Endpoint: POST /v1/restore
        let url = mint.appendingPathComponent("v1/restore")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        // Body: { "outputs": [ ... ] }
        let body: [String: Any] = [
            "outputs": outputs.map { ["amount": $0.amount, "B_": $0.B_, "id": $0.id] }
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (data, response) = try await session.data(for: request)
        
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let errorMsg = String(data: data, encoding: .utf8) ?? "Unknown"
            print("⚠️ Restore Failed: \(errorMsg)")
            throw CashuError.network("Restore failed with status: \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        
        // Response: { "outputs": [], "promises": [ { "amount": 1, "C": "..." }, ... ] }
        struct RestoreResponse: Decodable {
            let promises: [BlindSignatureDTO]
        }
        
        let decoded = try JSONDecoder().decode(RestoreResponse.self, from: data)
        return decoded.promises
    }
    
    public func check(mint: URL, proofs: [ProofDTO]) async throws -> [CheckStateDTO] {
        let url = mint.appendingPathComponent("v1/check")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let body: [String: Any] = [
            "proofs": proofs.map {
                ["amount": $0.amount, "secret": $0.secret, "C": $0.C, "id": $0.id]
            }
        ]
        
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (data, response) = try await session.data(for: request)
        
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw CashuError.network("Check failed with status: \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        
        struct CheckResponse: Decodable {
            let states: [CheckStateDTO]
        }
        
        let decoded = try JSONDecoder().decode(CheckResponse.self, from: data)
        return decoded.states
    }
    
    // In RealMintAPI.swift
    
    public func fetchKeysetIds(mint: URL) async throws -> [String] {
        // Try the standard V1 endpoint for all keysets
        struct KeysetsResponse: Decodable {
            struct KeysetInfo: Decodable {
                let id: String
                let active: Bool?
            }
            let keysets: [KeysetInfo]
        }
        
        // Handle trailing slash issues safely for the path
        let path = mint.path.hasSuffix("/") ? "v1/keysets" : "/v1/keysets"
        
        // We have to build the request manually here because getJSON uses self.baseURL
        let url = mint.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.timeoutInterval = 10 // Fast timeout for checks
        
        do {
            let (data, response) = try await session.data(for: request)
            
            if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                let r = try JSONDecoder().decode(KeysetsResponse.self, from: data)
                return r.keysets.map { $0.id }
            }
        } catch {
            // Ignore error, fall through to fallback
        }
        // 2. FALLBACK: If /v1/keysets doesn't exist, fetch the single active keyset
        let singleKeyset = try await fetchKeyset(mint: mint)
        return [singleKeyset.id]
    }
    
    // Fetch keys for a SPECIFIC keyset ID
    public func fetchKeyset(mint: URL, id: String) async throws -> Keyset {
        // 1. Construct URL: /v1/keys/{keyset_id}
        // Safe URL handling for the ID
        let path = "v1/keys/\(id)"
        let url = mint.appendingPathComponent(path)
        
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        
        let (data, response) = try await session.data(for: request)
        
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw CashuError.network("Could not fetch keys for ID \(id)")
        }
        
        // 2. Decode Response (NUT-01 format)
        struct KeysResponse: Decodable {
            struct KeysetInfo: Decodable {
                let id: String
                let keys: [String: String]
            }
            let keysets: [KeysetInfo]
        }
        
        let r = try JSONDecoder().decode(KeysResponse.self, from: data)
        
        // 3. Convert to internal Keyset model
        guard let ks = r.keysets.first else {
            throw CashuError.protocolError("Empty keyset response for ID \(id)")
        }
        
        var map: [Int64: String] = [:]
        for (k, v) in ks.keys {
            if let amt = Int64(k) { map[amt] = v }
        }
        
        return Keyset(id: ks.id, keys: map)
    }
}

private struct MintingResponse: Decodable {
    struct BlindSignature: Decodable {
        let amount: Int64
        let C_: String     // The blind signature
        let id: String?    // The keyset ID
    }
    let signatures: [BlindSignature]
}


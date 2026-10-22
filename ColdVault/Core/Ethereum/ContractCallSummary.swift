//
//  ContractCallSummary.swift
//  ColdVault
//
//  What a transaction from a dApp does, in words, for the review. Only calls whose meaning is
//  certain are named (token approvals and transfers, NFT approvals and transfers, wrapping);
//  anything else is shown as an unknown contract call with its function selector, never explained
//  by a guess. The worst case, an approval that lets another address spend everything, is flagged.
//

import Foundation

public struct ContractCallSummary: Equatable {
    public enum Risk { case none, caution, danger }

    public let risk: Risk
    public let english: String
    public let spanish: String

    public func text(_ language: AppLanguage) -> String { language == .english ? english : spanish }

    /// A value of at least 2^255 is how "unlimited" is written.
    private static func isUnlimited(_ word: Data) -> Bool {
        guard let first = word.first else { return false }
        return first >= 0x80
    }

    private static func address(_ word: Data) -> String {
        EthereumAddress.checksummed(Data(word.suffix(20)))
    }

    private static func words(_ data: Data) -> [Data] {
        let body = data.dropFirst(4)
        return stride(from: 0, to: body.count - body.count % 32, by: 32).map {
            Data(body.dropFirst($0).prefix(32))
        }
    }

    /// The call `data` makes (empty data is a plain transfer of the coin).
    public static func describe(data: Data) -> ContractCallSummary {
        guard data.count >= 4 else {
            return ContractCallSummary(risk: .none, english: "Plain transfer of the network's coin.",
                                       spanish: "Transferencia simple de la moneda de la red.")
        }
        let selector = Data(data.prefix(4)).hexEncodedString
        let w = words(data)
        switch selector {
        case "095ea7b3" where w.count >= 2:                  // approve(address,uint256)
            let spender = address(w[0])
            if w[1].allSatisfy({ $0 == 0 }) {
                return ContractCallSummary(risk: .none, english: "Removes the permission of \(spender) to spend this token.",
                                           spanish: "Quita el permiso de \(spender) para gastar este token.")
            }
            if isUnlimited(w[1]) {
                return ContractCallSummary(risk: .danger,
                                           english: "Lets \(spender) spend ALL of this token you hold, now and later, with no limit.",
                                           spanish: "Deja que \(spender) gaste TODO este token que tengas, ahora y después, sin límite.")
            }
            return ContractCallSummary(risk: .caution, english: "Lets \(spender) spend this token, up to the amount in the call.",
                                       spanish: "Deja que \(spender) gaste este token, hasta la cantidad de la llamada.")
        case "39509351" where w.count >= 2:                  // increaseAllowance(address,uint256)
            let spender = address(w[0])
            return ContractCallSummary(risk: isUnlimited(w[1]) ? .danger : .caution,
                                       english: "Raises how much of this token \(spender) may spend.",
                                       spanish: "Sube cuánto de este token puede gastar \(spender).")
        case "a22cb465" where w.count >= 2:                  // setApprovalForAll(address,bool)
            let operator_ = address(w[0])
            if w[1].allSatisfy({ $0 == 0 }) {
                return ContractCallSummary(risk: .none, english: "Removes the control of \(operator_) over your NFTs of this collection.",
                                           spanish: "Quita el control de \(operator_) sobre tus NFTs de esta colección.")
            }
            return ContractCallSummary(risk: .danger,
                                       english: "Gives \(operator_) control of ALL your NFTs of this collection: it can move them without asking again.",
                                       spanish: "Da a \(operator_) el control de TODOS tus NFTs de esta colección: puede moverlos sin volver a preguntarte.")
        case "a9059cbb" where w.count >= 2:                  // transfer(address,uint256)
            return ContractCallSummary(risk: .caution, english: "Sends tokens to \(address(w[0])).",
                                       spanish: "Envía tokens a \(address(w[0])).")
        case "23b872dd" where w.count >= 3:                  // transferFrom(address,address,uint256)
            return ContractCallSummary(risk: .caution, english: "Moves a token or NFT from \(address(w[0])) to \(address(w[1])).",
                                       spanish: "Mueve un token o NFT de \(address(w[0])) a \(address(w[1])).")
        case "42842e0e" where w.count >= 3, "b88d4fde" where w.count >= 3:   // safeTransferFrom
            return ContractCallSummary(risk: .caution, english: "Moves an NFT from \(address(w[0])) to \(address(w[1])).",
                                       spanish: "Mueve un NFT de \(address(w[0])) a \(address(w[1])).")
        case "87517c45" where w.count >= 3:                  // Permit2 approve(token, spender, amount, expiration)
            let spender = address(w[1])
            return ContractCallSummary(risk: .danger,
                                       english: "Lets \(spender) move this token for you through Permit2, until the permission expires.",
                                       spanish: "Deja que \(spender) mueva este token por ti a través de Permit2, hasta que caduque el permiso.")
        case "2eb2c2d6" where w.count >= 3:                  // safeBatchTransferFrom (ERC-1155)
            return ContractCallSummary(risk: .caution, english: "Moves several NFTs from \(address(w[0])) to \(address(w[1])).",
                                       spanish: "Mueve varios NFTs de \(address(w[0])) a \(address(w[1])).")
        case "d505accf":                                     // permit(...)
            return ContractCallSummary(risk: .danger,
                                       english: "Uses a signed permission to let an address spend this token.",
                                       spanish: "Usa un permiso firmado para dejar que una dirección gaste este token.")
        case "d0e30db0":                                     // deposit()
            return ContractCallSummary(risk: .none, english: "Wraps the coin sent into its token form (deposit).",
                                       spanish: "Convierte la moneda enviada a su forma de token (depósito).")
        case "2e1a7d4d":                                     // withdraw(uint256)
            return ContractCallSummary(risk: .none, english: "Unwraps the token back into the coin (withdraw).",
                                       spanish: "Convierte el token de vuelta a la moneda (retiro).")
        default:
            return ContractCallSummary(risk: .caution,
                                       english: "Calls a contract function ColdVault can't explain (0x\(selector)). Only continue if you trust this site.",
                                       spanish: "Llama a una función de un contrato que ColdVault no sabe explicar (0x\(selector)). Continúa solo si confías en este sitio.")
        }
    }
}

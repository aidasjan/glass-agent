//
// GlassAgentAPI.swift
//
// Thin client for the Glass Agent backend: customers, jobs, /ask, wrap-up.
//

import Foundation

struct Equipment: Codable, Identifiable, Hashable, Sendable {
  let id: String
  let make: String
  let model: String
  let location: String
}

struct Customer: Codable, Identifiable, Hashable, Sendable {
  let id: String
  let company: String
  let contactName: String
  let email: String
  let address: String
  let equipment: [Equipment]?
}

struct JobNote: Codable, Hashable, Sendable {
  let question: String
  let answer: String
}

struct Job: Codable, Identifiable, Sendable {
  let id: String
  let customerId: String
  let status: String
  let notes: [JobNote]
}

struct JobResponse: Codable, Sendable {
  let job: Job
  let customer: Customer
}

struct Part: Codable, Hashable, Sendable {
  let sku: String
  let name: String
  let price: Double
}

struct AskResponse: Codable, Sendable {
  let answer: String
  let fallback: Bool
  let equipment: Equipment?
  let suspectedIssue: String?
  let recommendedParts: [Part]
}

struct ReportLine: Codable, Hashable, Sendable {
  let sku: String
  let name: String
  let qty: Int
  let unitPrice: Double
  let amount: Double
}

struct Labor: Codable, Sendable {
  let hours: Double
  let rate: Double
  let amount: Double
}

struct ReportEquipment: Codable, Sendable {
  let make: String
  let model: String
  let location: String
  let serial: String
}

struct ReportCustomer: Codable, Sendable {
  let company: String
  let contactName: String
  let email: String
}

struct Report: Codable, Sendable {
  let jobId: String
  let date: String
  let customer: ReportCustomer
  let equipment: ReportEquipment?
  let issue: String
  let fix: String
  let lines: [ReportLine]
  let labor: Labor
  let total: Double
}

struct BackOffice: Codable, Sendable {
  let agentId: String
  let dashboardUrl: String
}

struct WrapUpResponse: Codable, Sendable {
  let report: Report
  let spoken: String
  let fallback: Bool
  let backOffice: BackOffice?
}

enum APIError: LocalizedError {
  case badURL
  case server(String)
  case network(String)

  var errorDescription: String? {
    switch self {
    case .badURL: return "Set the backend URL in settings."
    case .server(let message): return message
    case .network(let message): return message
    }
  }
}

struct GlassAgentAPI: Sendable {
  let baseURL: String

  private static let session: URLSession = {
    let config = URLSessionConfiguration.default
    config.timeoutIntervalForRequest = 45
    config.timeoutIntervalForResource = 60
    return URLSession(configuration: config)
  }()

  private static let decoder: JSONDecoder = {
    let d = JSONDecoder()
    d.keyDecodingStrategy = .convertFromSnakeCase
    return d
  }()

  struct Health: Codable, Sendable {
    let ok: Bool
    let anthropicKey: Bool
  }

  func health() async throws -> Health {
    try await send(try request("health"))
  }

  func customers() async throws -> [Customer] {
    try await send(try request("customers"))
  }

  func startJob(customerId: String) async throws -> JobResponse {
    var req = try request("jobs", method: "POST")
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.httpBody = try JSONEncoder().encode(["customer_id": customerId])
    return try await send(req)
  }

  func ask(jobId: String, question: String, jpeg: Data?) async throws -> AskResponse {
    let boundary = "glass-agent-\(UUID().uuidString)"
    var req = try request("ask", method: "POST")
    req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

    var body = Data()
    func field(_ name: String, _ value: String) {
      body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
    }
    field("job_id", jobId)
    field("text", question)
    if let jpeg {
      body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"photo\"; filename=\"photo.jpg\"\r\nContent-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
      body.append(jpeg)
      body.append("\r\n".data(using: .utf8)!)
    }
    body.append("--\(boundary)--\r\n".data(using: .utf8)!)
    req.httpBody = body
    return try await send(req)
  }

  func wrapUp(jobId: String, text: String) async throws -> WrapUpResponse {
    var req = try request("jobs/\(jobId)/wrapup", method: "POST")
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.httpBody = try JSONEncoder().encode(["text": text])
    return try await send(req)
  }

  // MARK: - Plumbing

  private func request(_ path: String, method: String = "GET") throws -> URLRequest {
    let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    guard !trimmed.isEmpty, let url = URL(string: "\(trimmed)/\(path)") else { throw APIError.badURL }
    var req = URLRequest(url: url)
    req.httpMethod = method
    return req
  }

  private func send<T: Decodable>(_ req: URLRequest) async throws -> T {
    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await Self.session.data(for: req)
    } catch let error as URLError where error.code == .timedOut {
      throw APIError.network("The server took too long to answer.")
    } catch {
      throw APIError.network("Can't reach the server. Check the connection and backend URL.")
    }
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard (200..<300).contains(status) else {
      let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
      throw APIError.server(message ?? "Server error (\(status)).")
    }
    do {
      return try Self.decoder.decode(T.self, from: data)
    } catch {
      throw APIError.server("Unexpected response from the server.")
    }
  }
}

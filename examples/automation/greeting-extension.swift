#!/usr/bin/swift
import Foundation
struct Request: Decodable { let apiVersion: Int; let operation: String; let query: String; let preferences: [String: String] }
let request = try JSONDecoder().decode(Request.self, from: FileHandle.standardInput.readDataToEndOfFile())
let prefix = request.preferences["prefix"] ?? "Hello"
let response: [String: Any] = ["apiVersion": 1, "results": [["id": "greeting", "title": "\(prefix), \(request.query.isEmpty ? "world" : request.query)!", "subtitle": "Example local extension", "detail": "This native detail view comes from a JSON response.", "actions": [["id": "greet", "title": "Greet"]]]], "message": request.operation == "action" ? "Greeting action completed." : ""]
FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: response))

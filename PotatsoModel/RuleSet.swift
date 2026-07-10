//
//  RuleSet.swift
//
//  Created by LEI on 4/6/16.
//  Copyright © 2016 TouchingApp. All rights reserved.
//

import Foundation

public enum RuleSetError: Error {
    case invalidRuleSet
    case emptyName
    case nameAlreadyExists
}

public enum RuleSetSubscriptionError: LocalizedError {
    case invalidURL
    case invalidResponse(Int)
    case emptyRules

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid subscription URL"
        case .invalidResponse(let statusCode):
            return "Subscription request failed (HTTP \(statusCode))"
        case .emptyRules:
            return "No valid rules in subscription"
        }
    }
}

extension RuleSetError: CustomStringConvertible {
    
    public var description: String {
        switch self {
        case .invalidRuleSet:
            return "Invalid rule set"
        case .emptyName:
            return "Empty name"
        case .nameAlreadyExists:
            return "Name already exists"
        }
    }
    
}

public final class RuleSet: BaseModel {
    @objc public dynamic var editable = true
    @objc public dynamic var name = ""
    @objc public dynamic var remoteUpdatedAt: TimeInterval = Date().timeIntervalSince1970
    @objc public dynamic var desc = ""
    @objc public dynamic var ruleCount = 0
    @objc public dynamic var rulesJSON = ""
    @objc public dynamic var isSubscribe = false
    @objc public dynamic var isOfficial = false
    @objc public dynamic var subscriptionURL = ""
    @objc public dynamic var subscriptionActionRaw = RuleAction.Proxy.rawValue

    fileprivate var cachedRules: [Rule]? = nil

    public var rules: [Rule] {
        get {
            if let cachedRules = cachedRules {
                return cachedRules
            }
            updateCahcedRules()
            return cachedRules!
        }
        set {
            let json = (newValue.map({ $0.json }) as NSArray).jsonString() ?? ""
            rulesJSON = json
            updateCahcedRules()
            ruleCount = newValue.count
        }
    }

    public override func validate() throws {
        guard name.count > 0 else {
            throw RuleSetError.emptyName
        }
    }

    fileprivate func updateCahcedRules() {
        guard let jsonArray = rulesJSON.jsonArray() as? [[String: AnyObject]] else {
            cachedRules = []
            return
        }
        cachedRules = jsonArray.compactMap({ Rule(json: $0) })
    }

    public func addRule(_ rule: Rule) {
        var newRules = rules
        newRules.append(rule)
        rules = newRules
    }

    public func insertRule(_ rule: Rule, atIndex index: Int) {
        var newRules = rules
        newRules.insert(rule, at: index)
        rules = newRules
    }

    public func removeRule(atIndex index: Int) {
        var newRules = rules
        newRules.remove(at: index)
        rules = newRules
    }

    public func move(_ fromIndex: Int, toIndex: Int) {
        var newRules = rules
        let rule = newRules[fromIndex]
        newRules.remove(at: fromIndex)
        insertRule(rule, atIndex: toIndex)
        rules = newRules
    }

    public var subscriptionAction: RuleAction {
        get { return RuleAction(rawValue: subscriptionActionRaw) ?? .Proxy }
        set { subscriptionActionRaw = newValue.rawValue }
    }

    /// Downloads and validates a Surge ruleset without altering persisted rules.
    public static func downloadSubscription(from urlString: String, defaultAction: RuleAction, completion: @escaping ([Rule]?, Error?) -> Void) {
        guard let url = URL(string: urlString), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            completion(nil, RuleSetSubscriptionError.invalidURL)
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error { completion(nil, error); return }
            if let response = response as? HTTPURLResponse, !(200...299).contains(response.statusCode) {
                completion(nil, RuleSetSubscriptionError.invalidResponse(response.statusCode)); return
            }
            guard let data = data, let content = String(data: data, encoding: .utf8) else {
                completion(nil, RuleSetSubscriptionError.emptyRules); return
            }
            var seen = Set<String>()
            let rules = content.components(separatedBy: .newlines).compactMap { line -> Rule? in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
                let parts = trimmed.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                let ruleString = parts.count == 2 ? "\(parts[0]),\(parts[1]),\(defaultAction.rawValue)" : trimmed
                guard let rule = try? Rule(str: ruleString), seen.insert(rule.description).inserted else { return nil }
                return rule
            }
            guard !rules.isEmpty else { completion(nil, RuleSetSubscriptionError.emptyRules); return }
            completion(rules, nil)
        }.resume()
    }
    
    public override static func indexedProperties() -> [String] {
        return ["name"]
    }
    
}

extension RuleSet {
    
    public convenience init(dictionary: [String: AnyObject]) throws {
        self.init()
        guard let name = dictionary["name"] as? String else {
            throw RuleSetError.invalidRuleSet
        }
        self.name = name
        if DBUtils.objectExistOf(type: RuleSet.self, by: name) {
            self.name = "\(name) \(RuleSet.dateFormatter.string(from: Date()))"
        }
        guard let rulesStr = dictionary["rules"] as? [String] else {
            throw RuleSetError.invalidRuleSet
        }
        rules = try rulesStr.map({ try Rule(str: $0) })
    }
    
}

public func ==(lhs: RuleSet, rhs: RuleSet) -> Bool {
    return lhs.uuid == rhs.uuid
}

//
//  RuleSetConfigurationViewController.swift
//
//  Created by LEI on 3/9/16.
//  Copyright © 2016 TouchingApp. All rights reserved.
//

import UIKit
import Eureka
import PotatsoLibrary
import PotatsoModel

private let kRuleSetFormName = "name"

class RuleSetConfigurationViewController: FormViewController {

    var ruleSet: PotatsoModel.RuleSet
    var rules: [Rule]
    let isEdit: Bool
    var editable: Bool {
        return ruleSet.editable && !ruleSet.isSubscribe
    }
    var callback: ((PotatsoModel.RuleSet?) -> Void)?
    var editSection: Section = Section()

    init(ruleSet: PotatsoModel.RuleSet? = nil, callback: ((PotatsoModel.RuleSet?) -> Void)? = nil) {
        self.callback = callback
        if let ruleSet = ruleSet {
            self.ruleSet = RuleSet(value: ruleSet)
            self.isEdit = true
        }else {
            self.ruleSet = RuleSet()
            self.isEdit = false
        }
        self.rules = self.ruleSet.rules
        super.init(nibName: nil, bundle: nil)
    }
    
    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        if editable {
            navigationItem.title = isEdit ? "Edit Rule Set".localized() : "Add Rule Set".localized()
        }else {
            navigationItem.title = ruleSet.name
        }
        generateForm()
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if editable {
            navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(save))
        } else if ruleSet.isSubscribe {
            navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .refresh, target: self, action: #selector(refreshSubscription))
        }
        tableView?.reloadSections(IndexSet(integer: 1), with: .none)
    }

    @objc func refreshSubscription() {
        guard !ruleSet.subscriptionURL.isEmpty else {
            showTextHUD("Invalid subscription URL".localized(), dismissAfterDelay: 1.5)
            return
        }
        showProgreeHUD("Downloading rule subscription...".localized())
        RuleSet.downloadSubscription(from: ruleSet.subscriptionURL, defaultAction: ruleSet.subscriptionAction) { rules, error in
            DispatchQueue.main.async {
                self.hideHUD()
                guard let rules = rules, error == nil else {
                    self.showTextHUD("Fail to download rule subscription".localized() + ": \(error?.localizedDescription ?? "")", dismissAfterDelay: 2.0)
                    return
                }
                // Commit only after a full successful download and parse; prior rules remain active on failure.
                self.ruleSet.rules = rules
                self.ruleSet.remoteUpdatedAt = Date().timeIntervalSince1970
                do {
                    try DBUtils.add(self.ruleSet)
                    try Manager.sharedManager.regenerateConfigFiles()
                    self.rules = rules
                    self.generateForm()
                    self.showTextHUD(String(format: "Downloaded %d rules".localized(), rules.count), dismissAfterDelay: 1.5)
                } catch {
                    self.showTextHUD("Fail to save config.".localized() + ": \(error.localizedDescription)", dismissAfterDelay: 2.0)
                }
            }
        }
    }

    func generateForm() {
        form.removeAll()
        form +++ Section()
            <<< TextRow(kRuleSetFormName) {
                $0.title = "Name".localized()
                $0.value = self.ruleSet.name
                $0.disabled = Condition(booleanLiteral: !self.editable)
            }.cellSetup { cell, row in
                cell.textField.placeholder = "Rule Set Name".localized()
            }
        
        editSection = Section("Rule".localized())
        if editable {
            editSection <<< BaseButtonRow () {
                $0.title = "Add Rule".localized()
            }.cellUpdate({ (cell, row) in
                cell.textLabel?.textColor = Color.Brand
            }).onCellSelection({ [unowned self] (cell, row) -> () in
                self.showRuleConfiguration(nil)
            })
        }
        for rule in rules {
            insertRule(rule, atIndex: editSection.count)
        }
        form +++ editSection
    }

    func insertRule(_ rule: Rule, atIndex index: NSInteger) {
        editSection.insert(LabelRow () {
                $0.title = rule.rowDescription.0 == nil ? "" : "\(rule.rowDescription.0!)"
                $0.value = rule.rowDescription.1 == nil ? "" : "\(rule.rowDescription.1!)"
                $0.disabled = Condition(booleanLiteral: !self.editable)
            }.cellSetup({ (cell, row) -> () in
                cell.accessoryType = .disclosureIndicator
                cell.selectionStyle = .default
            }).cellUpdate({ (cell, row) -> () in
                row.title = rule.rowDescription.0 == nil ? "" : "\(rule.rowDescription.0!)"
                row.value = rule.rowDescription.1 == nil ? "" : "\(rule.rowDescription.1!)"
            }).onCellSelection({ [unowned self] (cell, row) -> () in
                self.showRuleConfiguration(rule)
            }),
            at: index)
    }
    
    func showRuleConfiguration(_ rule: Rule?) {
        let vc = RuleConfigurationViewController(rule: rule) { result in
            if rule == nil {
                self.insertRule(result, atIndex: self.form[1].count)
                self.ruleSet.addRule(result)
            }
        }
        vc.editable = editable
        navigationController?.pushViewController(vc, animated: true)
    }
    
    @objc func save() {
        do {
            let values = form.values()
            guard let name = (values[kRuleSetFormName] as? String)?.trimmingCharacters(in: CharacterSet.whitespaces), name.count > 0 else {
                throw "Name can't be empty".localized()
            }
            ruleSet.name = name
            try DBUtils.add(ruleSet)
            callback?(ruleSet)
            close()
        }catch {
            showTextHUD("\(error)", dismissAfterDelay: 1.0)
        }
    }
    
    override func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        if indexPath.section == 1 {
            return editable
        }
        return false
    }
    
    override func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCellEditingStyle, forRowAt indexPath: IndexPath) {
        if editingStyle == .delete {
            ruleSet.removeRule(atIndex: indexPath.row - 1)
            form[indexPath].hidden = true
            form[indexPath].evaluateHidden()
        }
    }
    
    override func tableView(_ tableView: UITableView, editingStyleForRowAt indexPath: IndexPath) -> UITableViewCellEditingStyle {
        return UITableViewCellEditingStyle.delete
    }
    
}

//
//  RuleSetListViewController.swift
//
//  Created by LEI on 5/31/16.
//  Copyright © 2016 TouchingApp. All rights reserved.
//

import Foundation
import PotatsoModel
import Cartography
import Realm
import RealmSwift

private let rowHeight: CGFloat = 54
private let kRuleSetCellIdentifier = "ruleset"

class RuleSetListViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {

    var ruleSets: Results<RuleSet>
    var chooseCallback: ((RuleSet?) -> Void)?
    // Observe Realm Notifications
    var token: RLMNotificationToken?
    var heightAtIndex: [Int: CGFloat] = [:]

    init(chooseCallback: ((RuleSet?) -> Void)? = nil) {
        self.chooseCallback = chooseCallback
        self.ruleSets = DBUtils.allNotDeleted(RuleSet.self, sorted: "createAt")
        super.init(nibName: nil, bundle: nil)
    }
    
    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationItem.title = "Rule Set".localized()
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .add, target: self, action: #selector(add))
        reloadData()
        token = ruleSets.observe(on: DBUtils.sharedQueueForRealm) { [unowned self] changed in
            switch changed {
            case let .update(_, deletions: deletions, insertions: insertions, modifications: modifications):
                self.tableView.beginUpdates()
                defer {
                    self.tableView.endUpdates()
                }
                self.tableView.deleteRows(at: deletions.map({ IndexPath(row: $0, section: 0) }), with: .automatic)
                self.tableView.insertRows(at: insertions.map({ IndexPath(row: $0, section: 0) }), with: .automatic)
                self.tableView.reloadRows(at: modifications.map({ IndexPath(row: $0, section: 0) }), with: .none)
            case let .error(error):
                let name = String(describing: type(of: self))
                error.log("\(name) realm token update error")
            default:
                break
            }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        token?.invalidate()
    }

    func reloadData() {
        ruleSets = DBUtils.allNotDeleted(RuleSet.self, sorted: "createAt")
        tableView.reloadData()
    }

    @objc func add() {
        let alert = UIAlertController(title: "Add Rule Set".localized(), message: nil, preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: "Create manually".localized(), style: .default) { _ in
            self.navigationController?.pushViewController(RuleSetConfigurationViewController(), animated: true)
        })
        alert.addAction(UIAlertAction(title: "Add Rule Subscription".localized(), style: .default) { _ in self.addSubscription() })
        alert.addAction(UIAlertAction(title: "Cancel".localized(), style: .cancel))
        alert.popoverPresentationController?.barButtonItem = navigationItem.rightBarButtonItem
        present(alert, animated: true)
    }

    func addSubscription() {
        let alert = UIAlertController(title: "Add Rule Subscription".localized(), message: nil, preferredStyle: .alert)
        alert.addTextField { $0.placeholder = "Name".localized(); $0.text = "GFW List" }
        alert.addTextField {
            $0.placeholder = "Subscription URL".localized()
            $0.text = "https://raw.githubusercontent.com/Loyalsoldier/surge-rules/release/ruleset/gfw.txt"
            $0.keyboardType = .URL
            $0.autocapitalizationType = .none
            $0.autocorrectionType = .no
        }
        alert.addAction(UIAlertAction(title: "Cancel".localized(), style: .cancel))
        alert.addAction(UIAlertAction(title: "Download".localized(), style: .default) { _ in
            let name = alert.textFields?[0].text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let url = alert.textFields?[1].text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !name.isEmpty else { self.showTextHUD("Name can't be empty".localized(), dismissAfterDelay: 1.5); return }
            self.downloadSubscription(name: name, url: url)
        })
        present(alert, animated: true)
    }

    func downloadSubscription(name: String, url: String) {
        showProgreeHUD("Downloading rule subscription...".localized())
        RuleSet.downloadSubscription(from: url, defaultAction: .Proxy) { rules, error in
            DispatchQueue.main.async {
                self.hideHUD()
                guard let rules = rules, error == nil else {
                    self.showTextHUD("Fail to download rule subscription".localized() + ": \(error?.localizedDescription ?? "")", dismissAfterDelay: 2.0)
                    return
                }
                let ruleSet = RuleSet()
                ruleSet.name = name
                ruleSet.isSubscribe = true
                ruleSet.subscriptionURL = url
                ruleSet.subscriptionAction = .Proxy
                ruleSet.rules = rules
                ruleSet.remoteUpdatedAt = Date().timeIntervalSince1970
                do {
                    try DBUtils.add(ruleSet)
                    self.showTextHUD(String(format: "Downloaded %d rules".localized(), rules.count), dismissAfterDelay: 1.5)
                    if let callback = self.chooseCallback { callback(ruleSet); self.close() }
                } catch {
                    self.showTextHUD("Fail to save config.".localized() + ": \(error.localizedDescription)", dismissAfterDelay: 2.0)
                }
            }
        }
    }

    func showRuleSetConfiguration(_ ruleSet: RuleSet?) {
        let vc = RuleSetConfigurationViewController(ruleSet: ruleSet)
        navigationController?.pushViewController(vc, animated: true)
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return ruleSets.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: kRuleSetCellIdentifier, for: indexPath) as! RuleSetCell
        cell.setRuleSet(ruleSets[indexPath.row], showSubscribe: true)
        return cell
    }

    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        heightAtIndex[indexPath.row] = cell.frame.size.height
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let ruleSet = ruleSets[indexPath.row]
        if let cb = chooseCallback {
            cb(ruleSet)
            close()
        }else {
            showRuleSetConfiguration(ruleSet)
        }
    }

    func tableView(_ tableView: UITableView, estimatedHeightForRowAt indexPath: IndexPath) -> CGFloat {
        if let height = heightAtIndex[indexPath.row] {
            return height
        } else {
            return UITableViewAutomaticDimension
        }
    }

    func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        return chooseCallback == nil
    }

    func tableView(_ tableView: UITableView, editingStyleForRowAt indexPath: IndexPath) -> UITableViewCellEditingStyle {
        return .delete
    }

    func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCellEditingStyle, forRowAt indexPath: IndexPath) {
        if editingStyle == .delete {
            let item: RuleSet
            guard indexPath.row < ruleSets.count else {
                return
            }
            item = ruleSets[indexPath.row]
            do {
                try DBUtils.softDelete(item.uuid, type: RuleSet.self)
            }catch {
                self.showTextHUD("\("Fail to delete item".localized()): \((error as NSError).localizedDescription)", dismissAfterDelay: 1.5)
            }
        }
    }
    

    override func loadView() {
        super.loadView()
        view.backgroundColor = UIColor.init(red: 0.0, green: 0.0, blue: 0.0, alpha: 0.0)
        view.addSubview(tableView)
        tableView.register(RuleSetCell.self, forCellReuseIdentifier: kRuleSetCellIdentifier)

        constrain(tableView, view) { tableView, view in
            tableView.edges == view.edges
        }
    }

    lazy var tableView: UITableView = {
        let v = UITableView(frame: CGRect.zero, style: .plain)
        v.dataSource = self
        v.delegate = self
        v.tableFooterView = UIView()
        v.tableHeaderView = UIView()
        v.separatorStyle = .singleLine
        v.rowHeight = UITableViewAutomaticDimension
        return v
    }()

}

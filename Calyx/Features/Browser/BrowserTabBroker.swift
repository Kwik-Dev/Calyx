import Foundation

@MainActor
class BrowserTabBroker {
    weak var appDelegate: AppDelegate?

    func resolveTab(_ tabID: UUID?) -> BrowserTabController? {
        guard let appDelegate else { return nil }
        if let tabID {
            // Search ALL windows for this tab
            for wc in appDelegate.allWindowControllers {
                if let controller = wc.browserController(forExternal: tabID) {
                    return controller
                }
            }
            return nil
        }
        // No tab_id → active browser tab in AppDelegate
        // .currentWindowController (the key window, else the front-most
        // window that is visible and on the active Space, else the last
        // one that was key, else the first open window).
        return appDelegate.currentWindowController?.activeBrowserControllerForExternal
    }

    func listTabs() -> [(id: UUID, url: String, title: String)] {
        guard let appDelegate else { return [] }
        var result: [(id: UUID, url: String, title: String)] = []
        for wc in appDelegate.allWindowControllers {
            for group in wc.windowSession.groups {
                for tab in group.tabs {
                    if case .browser(let url) = tab.content {
                        result.append((id: tab.id, url: url.absoluteString, title: tab.title))
                    }
                }
            }
        }
        return result
    }

    func createTab(url: URL) -> UUID? {
        guard let appDelegate else { return nil }
        guard let wc = appDelegate.currentWindowController else { return nil }
        wc.createBrowserTab(url: url)
        // The last browser tab added to the active group is the one we just created
        guard let group = wc.windowSession.activeGroup,
              let lastTab = group.tabs.last,
              case .browser = lastTab.content else { return nil }
        return lastTab.id
    }
}

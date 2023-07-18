//
//  LocalAccountRefresher.swift
//  NetNewsWire
//
//  Created by Brent Simmons on 9/6/16.
//  Copyright © 2016 Ranchero Software, LLC. All rights reserved.
//

import Foundation
import RSCore
import RSParser
import RSWeb
import Articles
import ArticlesDatabase

protocol LocalAccountRefresherDelegate {
	func localAccountRefresher(_ refresher: LocalAccountRefresher, requestCompletedFor: Feed)
	func localAccountRefresher(_ refresher: LocalAccountRefresher, articleChanges: ArticleChanges, completion: @escaping () -> Void)
}

final class LocalAccountRefresher {
	
	private var completion: (() -> Void)? = nil
	private var isSuspended = false
	var delegate: LocalAccountRefresherDelegate?
	
	private lazy var downloadSession: DownloadSession = {
		return DownloadSession(delegate: self)
	}()

	public func refreshFeeds(_ feeds: Set<Feed>, completion: (() -> Void)? = nil) {
		guard !feeds.isEmpty else {
			completion?()
			return
		}
        
        let redditFeeds = feeds.filter { feed in
            if let url = feed.homePageURL {
                return url.contains("reddit.com")
            }
            else {
                return false
            }
        }
        let otherFeeds = feeds.subtracting(redditFeeds)
        
        //Download non reddit feeds first
        self.downloadSession.downloadObjects(otherFeeds as NSSet)
        
        //Download reddit feeds if they exist
        if redditFeeds.count > 0 {
            
            batchFeeds(feedList: Array(redditFeeds), batchSize: 100, delay: 601) //100 requests per 10 minutes (601 seconds).
            
            func batchFeeds(feedList: [Feed], batchSize: Int, delay: Int, index: Int = 0) {
                guard feedList.count > 0 else { return }
                
                print(feedList.count, index)
                
                let batch = Set(feedList[0..<min(feedList.count, batchSize)])
                let nextList = Array(feedList.dropFirst(batchSize))
                
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(delay * index)) {
                    self.downloadSession.downloadObjects(batch as NSSet)
                    
                    //Only run the completion on the last batch as on completion it closes the group in LocalAccountDelegate.swift
                    if nextList.count == 0 { self.completion = completion }
                }
                
                batchFeeds(feedList: nextList, batchSize: batchSize, delay: delay, index: index + 1)
            }
        }
        else {
             self.completion = completion
        }
	}
	
	public func suspend() {
		downloadSession.cancelAll()
		isSuspended = true
	}
	
	public func resume() {
		isSuspended = false
	}
	
}

// MARK: - DownloadSessionDelegate

extension LocalAccountRefresher: DownloadSessionDelegate {

	func downloadSession(_ downloadSession: DownloadSession, requestForRepresentedObject representedObject: AnyObject) -> URLRequest? {
		guard let feed = representedObject as? Feed else {
			return nil
		}
		guard let url = URL(string: feed.url) else {
			return nil
		}
		
		var request = URLRequest(url: url)
		if let conditionalGetInfo = feed.conditionalGetInfo {
			conditionalGetInfo.addRequestHeadersToURLRequest(&request)
		}

		return request
	}
	
	func downloadSession(_ downloadSession: DownloadSession, downloadDidCompleteForRepresentedObject representedObject: AnyObject, response: URLResponse?, data: Data, error: NSError?, completion: @escaping () -> Void) {
		let feed = representedObject as! Feed
		
		guard !data.isEmpty, !isSuspended else {
			completion()
			delegate?.localAccountRefresher(self, requestCompletedFor: feed)
			return
		}

		if let error = error {
			print("Error downloading \(feed.url) - \(error)")
			completion()
			delegate?.localAccountRefresher(self, requestCompletedFor: feed)
			return
		}

		let dataHash = data.md5String
		if dataHash == feed.contentHash {
			completion()
			delegate?.localAccountRefresher(self, requestCompletedFor: feed)
			return
		}

		let parserData = ParserData(url: feed.url, data: data)
		FeedParser.parse(parserData) { (parsedFeed, error) in

            Task { @MainActor in
                guard let account = feed.account, let parsedFeed = parsedFeed, error == nil else {
                    completion()
                    self.delegate?.localAccountRefresher(self, requestCompletedFor: feed)
                    return
                }

                account.update(feed, with: parsedFeed) { result in
                    if case .success(let articleChanges) = result {
                        if let httpResponse = response as? HTTPURLResponse {
                            feed.conditionalGetInfo = HTTPConditionalGetInfo(urlResponse: httpResponse)
                        }
                        feed.contentHash = dataHash
                        self.delegate?.localAccountRefresher(self, requestCompletedFor: feed)
                        self.delegate?.localAccountRefresher(self, articleChanges: articleChanges) {
                            completion()
                        }
                    } else {
                        completion()
                        self.delegate?.localAccountRefresher(self, requestCompletedFor: feed)
                    }
                }
            }
		}
	}
	
	func downloadSession(_ downloadSession: DownloadSession, shouldContinueAfterReceivingData data: Data, representedObject: AnyObject) -> Bool {
		let feed = representedObject as! Feed
		guard !isSuspended else {
			delegate?.localAccountRefresher(self, requestCompletedFor: feed)
			return false
		}
		
		if data.isEmpty {
			return true
		}
		
		if data.isDefinitelyNotFeed() {
			delegate?.localAccountRefresher(self, requestCompletedFor: feed)
			return false
		}
		
		return true		
	}

	func downloadSession(_ downloadSession: DownloadSession, didReceiveUnexpectedResponse response: URLResponse, representedObject: AnyObject) {
		let feed = representedObject as! Feed
		delegate?.localAccountRefresher(self, requestCompletedFor: feed)
	}

	func downloadSession(_ downloadSession: DownloadSession, didReceiveNotModifiedResponse: URLResponse, representedObject: AnyObject) {
		let feed = representedObject as! Feed
		delegate?.localAccountRefresher(self, requestCompletedFor: feed)
	}
	
	func downloadSession(_ downloadSession: DownloadSession, didDiscardDuplicateRepresentedObject representedObject: AnyObject) {
		let feed = representedObject as! Feed
		delegate?.localAccountRefresher(self, requestCompletedFor: feed)
	}

	func downloadSessionDidCompleteDownloadObjects(_ downloadSession: DownloadSession) {
		completion?()
		completion = nil
	}

}

// MARK: - Utility

private extension Data {
	
	func isDefinitelyNotFeed() -> Bool {
		// We only detect a few image types for now. This should get fleshed-out at some later date.
		return self.isImage
	}
}

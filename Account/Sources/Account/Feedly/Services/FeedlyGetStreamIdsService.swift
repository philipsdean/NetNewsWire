//
//  FeedlyGetStreamIDsService.swift
//  Account
//
//  Created by Kiel Gillard on 21/10/19.
//  Copyright © 2019 Ranchero Software, LLC. All rights reserved.
//

import Foundation

protocol FeedlyGetStreamIDsService: AnyObject {
	func streamIDs(for resource: FeedlyResourceId, continuation: String?, newerThan: Date?, unreadOnly: Bool?, completion: @escaping (Result<FeedlyStreamIDs, Error>) -> ())
}

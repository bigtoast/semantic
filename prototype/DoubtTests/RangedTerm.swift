struct RangedTerm {
	typealias Term = Cofree<String, Range<String.Index>>
	let term: Term
	let source: String
}

extension RangedTerm: Arbitrary {
	static var arbitrary: Gen<RangedTerm> {
		return UnannotatedTerm.arbitrary.fmap { $0.arranged }
	}
}


@testable import Doubt
import Prelude
import SwiftCheck

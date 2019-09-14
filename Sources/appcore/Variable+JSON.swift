//
//  Variable+JSON.swift
//  kappserver
//
//  Created by Mark Lilback on 9/13/19.
//

import Foundation
import Rc2Model
import servermodel
import Logging

struct VariableError: Error {
	let reason: String
	let nestedError: Error?
	init(_ reason: String, error: Error? = nil) {
		self.reason = reason
		self.nestedError = error
	}
}


extension Variable {
	static let rDateFormatter: ISO8601DateFormatter = { var f = ISO8601DateFormatter(); f.formatOptions = [.withFullDate, .withDashSeparatorInDate]; return f}()
	
	/// Parses a legacy compute json dictionary into a Variable
	public static func makeFromLegacy(json: JSON, logger: Logger?) throws -> Variable {
		do {
			guard let vname = json["name"].string else { throw VariableError("missing name") }
			guard let className = json["class"].string else { throw VariableError("missing className") }
			let vlen = json["length"].int
			let summary = json["summary"].string ?? ""
			let primitive = json["primitive"].bool ?? false
			let s4 = json["s4"].bool ?? false
			var vtype: VariableType
			if primitive {
				vtype = .primitive(try makePrimitive(json: json))
			} else if s4 {
				vtype = .s4Object
			} else {
				switch className {
				case "Date":
					do {
						guard let dateStr = json["value"].string, let vdate = rDateFormatter.date(from: dateStr)
							else { throw VariableError("invalid date value") }
						vtype = .date(vdate)
					} catch {
						throw VariableError("invalid date value", error: error)
					}
				case "POSIXct", "POSIXlt":
					do {
						guard let dateVal = json["value"].double
							else { throw VariableError("invalid date value") }
						vtype = .dateTime(Date(timeIntervalSince1970: dateVal))
					} catch {
						throw VariableError("invalid date value", error: error)
					}
				case "function":
					do {
						guard let str = json["body"].string
							else { throw VariableError("function w/o body") }
						vtype = .function(str)
					} catch {
						throw VariableError("function w/o body", error: error)
					}
				case "factor", "ordered factor":
					let rawLevels = json["levels"].array ?? []
					let levels: [String] = rawLevels.compactMap { $0.string }
					let vals = json["value"].array?.compactMap { $0.int } ?? []
					vtype = .factor(values: vals, levelNames: levels)
					guard rawLevels.count == 0 || rawLevels.count == vals.count
						else { throw VariableError("factor missing values", error: nil) }
				case "matrix":
					vtype = .matrix(try parseMatrix(json: json))
				case "environment":
					vtype = .environment // FIXME: need to parse key/value pairs sent as value
				case "data.frame":
					vtype = .dataFrame(try parseDataFrame(json: json))
				case "list":
					vtype = .list([]) // FIXME: need to parse
				default:
					//make sure it is an object we can handle
					guard json["generic"].bool ?? false
						else { throw VariableError("unknown parsing error \(className)") }
					var attrs = [String: Variable]()
					let rawValues = json["value"].dictionary ?? [:]
					let names = json["value"].array?.compactMap { $0.string } ?? []
					for aName in names {
						if let attrJson = rawValues[aName], let value = try? makeFromLegacy(json: attrJson, logger: logger) {
							attrs[aName] = value
						}
					}
					vtype = .generic(attrs)
				}
			}
			return Variable(name: vname, length: vlen ?? 0, type: vtype, className: className, summary: summary)
		} catch let verror as VariableError {
			throw verror
		} catch {
			logger?.warning("error parsing legacy variable: \(error)")
			throw VariableError("error parsing legacy variable", error: error)
		}
	}
	
	static func parseDataFrame(json: JSON) throws -> DataFrameData {
		do {
			guard let numCols = json["ncol"].int,
				let numRows = json["nrow"].int
				else { throw VariableError.init("dataframe requires num rows and cols") }
			let rowNames: [String] = json["row.names"].array?.compactMap { $0.string } ?? []
			let rawColumns = json["columns"]
			let columns = try rawColumns.array!.map { (colJson: JSON) -> DataFrameData.Column in
				guard let colName = colJson["name"].string
					else { throw VariableError("failed to parse df column names") }
				return DataFrameData.Column(name: colName, value: try makePrimitive(json: colJson, valueKey: "values"))
			}
			guard columns.count == numCols,
				rowNames.count == 0 || rowNames.count == numRows
				else { throw VariableError("data does not match num cols/rows") }
			return DataFrameData(columns: columns, rowCount: numRows, rowNames: rowNames)
		} catch let verror as VariableError {
			throw verror
		} catch {
			throw VariableError("error parsing data frame", error: error)
		}
	}
	
	static func parseMatrix(json: JSON) throws -> MatrixData {
		do {
			guard let numCols = json["ncol"].int,
				let numRows = json["nrow"].int
				else { throw VariableError.init("dataframe requires num rows and cols") }
			let rowNames: [String]? = json["dimnames"][0].array?.compactMap { $0.string }
			let colNames: [String]? = json["dimnames"][1].array?.compactMap { $0.string }
			guard rowNames == nil || rowNames!.count == numRows
				else { throw VariableError("row names do not match length") }
			guard colNames == nil || colNames!.count == numCols
				else { throw VariableError("col names do not match length") }
			let values = try makePrimitive(json: json)
			return MatrixData(value: values, rowCount: numRows, colCount: numCols, colNames: colNames, rowNames: rowNames)
		} catch let verror as VariableError {
			throw verror
		} catch {
			throw VariableError("error parsing matrix data", error: error)
		}
	}
	
	// parses array of doubles, "Inf", "-Inf", and "NaN" into [Double]
	static func parseDoubles(json: [JSON]) throws -> [Double?] {
		return try json.map { (aVal) in
			if aVal.double != nil { return aVal.double! }
			if aVal.int != nil { return Double(aVal.int!) }
			if aVal.string != nil {
				switch aVal.string! {
				case "Inf": return Double.infinity
				case "-Inf": return -Double.infinity
				case "NaN": return Double.nan
				default: throw VariableError("invalid string as double value \(aVal)")
				}
			}
			if aVal == .null { return nil }
			throw VariableError("invalid value type in double array")
		}
	}
	
	// returns a PrimitiveValue based on the contents of json
	static func makePrimitive(json: JSON, valueKey: String = "value") throws -> PrimitiveValue {
		guard let ptype = json["type"].string
			else { throw VariableError("invalid primitive type") }
		guard let rawValues = json[valueKey].array
			else { throw VariableError("invalid value") }
		var pvalue: PrimitiveValue
		switch ptype {
		case "n":
			pvalue = .null
		case "b":
			let bval: [Bool?] = try rawValues.map { (aVal: JSON) -> Bool? in
				if case .null = aVal { return nil }
				if case let .bool(aBool) = aVal { return aBool }
				throw VariableError("invalid bool variable \(aVal)")
			}
			pvalue = .boolean(bval)
		case "i":
			let ival: [Int?] = try rawValues.map { (aVal: JSON) -> Int? in
				if case .null = aVal { return nil }
				if let anInt = aVal.int { return anInt }
				throw VariableError("invalid int variable \(aVal)")
			}
			pvalue = .integer(ival)
		case "d":
			pvalue = .double(try parseDoubles(json: rawValues))
		case "s":
			let sval: [String?] = try rawValues.map { (aVal: JSON) -> String? in
				if case .null = aVal { return nil }
				if case let .string(aStr) = aVal { return aStr }
				throw VariableError("invalid string variable \(aVal)")
			}
			pvalue = .string(sval)
		case "c":
			let cval: [String?] = try rawValues.map { (aVal: JSON) -> String? in
				if case .null = aVal { return nil }
				if case let .string(aStr) = aVal { return aStr }
				throw VariableError("invalid complex variable \(aVal)")
			}
			pvalue = .complex(cval)
		case "r":
			pvalue = .raw
		default:
			throw VariableError("unknown primitive type: \(ptype)")
		}
		return  pvalue
	}
}

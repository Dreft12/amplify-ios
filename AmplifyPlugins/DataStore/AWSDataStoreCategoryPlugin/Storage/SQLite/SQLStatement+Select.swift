//
// Copyright Amazon.com Inc. or its affiliates.
// All Rights Reserved.
//
// SPDX-License-Identifier: Apache-2.0
//

import Amplify
import Foundation
import SQLite

/// Support data structure used to hold information about `SelectStatement` than
/// can be used later to parse the results.
struct SelectStatementMetadata {

    typealias ColumnMapping = [String: (ModelSchema, ModelField)]

    let statement: String
    let columnMapping: ColumnMapping
    let bindings: [Binding?]

    static func metadata(from modelSchema: ModelSchema,
                         predicate: QueryPredicate? = nil,
                         sort: [QuerySortDescriptor]? = nil,
                         paginationInput: QueryPaginationInput? = nil) -> SelectStatementMetadata {
        let rootNamespace = "root"
        let fields = modelSchema.columns
        let tableName = modelSchema.name
        var columnMapping: ColumnMapping = [:]
        var columns = fields.map { field -> String in
            columnMapping.updateValue((modelSchema, field), forKey: field.name)
            return field.columnName(forNamespace: rootNamespace) + " as " + field.columnAlias()
        }

        // eager load many-to-one/one-to-one relationships
        let joinStatements = joins(from: modelSchema)
        columns += joinStatements.columns
        columnMapping.merge(joinStatements.columnMapping) { _, new in new }

        var sql = """
        select
          \(joinedAsSelectedColumns(columns))
        from "\(tableName)" as "\(rootNamespace)"
        \(joinStatements.statements.joined(separator: "\n"))
        """.trimmingCharacters(in: .whitespacesAndNewlines)

        var bindings: [Binding?] = []
        if let predicate = predicate {
            let conditionStatement = ConditionStatement(modelSchema: modelSchema,
                                                        predicate: predicate,
                                                        namespace: rootNamespace[...])
            bindings.append(contentsOf: conditionStatement.variables)
            sql = """
            \(sql)
            where 1 = 1
            \(conditionStatement.stringValue)
            """
        }

        if let sort = sort, !sort.isEmpty {
            sql = """
            \(sql)
            order by \(sort.sortStatement(namespace: rootNamespace))
            """
        }

        if let paginationInput = paginationInput {
            sql = """
            \(sql)
            \(paginationInput.sqlStatement)
            """
        }

        return SelectStatementMetadata(statement: sql,
                                       columnMapping: columnMapping,
                                       bindings: bindings)
    }

    struct JoinStatement {
        let columns: [String]
        let statements: [String]
        let columnMapping: ColumnMapping
    }

    /// Walk through the associations recursively to generate join statements.
    ///
    /// Implementation note: this should be revisited once we define support
    /// for explicit `eager` vs `lazy` associations.
    private static func joins(from schema: ModelSchema) -> JoinStatement {
        var columns: [String] = []
        var joinStatements: [String] = []
        var columnMapping: ColumnMapping = [:]

        func visitAssociations(node: ModelSchema, namespace: String = "root") {
            for (associatedModelName, foreignKeyFields) in node.foreignKeys {
                guard let associatedSchema = ModelRegistry.modelSchema(from: associatedModelName) else {
                    preconditionFailure("""
                    Could not retrieve schema for the model \(associatedModelName), verify that datastore is
                    initialized.
                    """)
                }
                let associatedTableName = associatedSchema.name

                // columns
                let aliasBaseName = foreignKeyFields.count == 1 ? foreignKeyFields[0].name : "\(associatedModelName)Ref"
                let alias = namespace == "root" ? aliasBaseName : "\(namespace).\(aliasBaseName)"

                let associatedColumns = associatedSchema.primaryKey.map { $0.columnName(forNamespace: alias) }
                let foreignKeyNames = foreignKeyFields.map { $0.columnName(forNamespace: namespace) }

                // append columns from relationships
                columns += associatedSchema.columns.map { field -> String in
                    columnMapping.updateValue((associatedSchema, field), forKey: "\(alias).\(field.name)")
                    return field.columnName(forNamespace: alias) + " as " + field.columnAlias(forNamespace: alias)
                }

                let joinType = foreignKeyFields.isRequired ? "inner" : "left outer"
                let searchCondition = zip(associatedColumns, foreignKeyNames)
                    .map { "\($0) = \($1)" }
                    .joined(separator: " AND ")

                joinStatements.append("""
                \(joinType) join \"\(associatedTableName)\" as "\(alias)"
                  on \(searchCondition)
                """)
                visitAssociations(node: associatedSchema, namespace: alias)
            }
        }
        visitAssociations(node: schema)

        return JoinStatement(columns: columns,
                             statements: joinStatements,
                             columnMapping: columnMapping)
    }

}

/// Represents a `select` SQL statement associated with a `Model` instance and
/// optionally composed by a `ConditionStatement`.
struct SelectStatement: SQLStatement {

    let modelSchema: ModelSchema
    let metadata: SelectStatementMetadata

    init(from modelSchema: ModelSchema,
         predicate: QueryPredicate? = nil,
         sort: [QuerySortDescriptor]? = nil,
         paginationInput: QueryPaginationInput? = nil) {
        self.modelSchema = modelSchema
        self.metadata = .metadata(from: modelSchema,
                                  predicate: predicate,
                                  sort: sort,
                                  paginationInput: paginationInput)
    }

    var stringValue: String {
        metadata.statement
    }

    var variables: [Binding?] {
        metadata.bindings
    }

}

// MARK: - Helpers

/// Join a list of table columns joined and formatted for readability.
///
/// - Parameter columns the list of column names
/// - Parameter perLine max numbers of columns per line
/// - Returns: a list of columns that can be used in `select` SQL statements
internal func joinedAsSelectedColumns(_ columns: [String], perLine: Int = 3) -> String {
    return columns.enumerated().reduce("") { partial, entry in
        let spacer = entry.offset == 0 || entry.offset % perLine == 0 ? "\n  " : " "
        let isFirstOrLast = entry.offset == 0 || entry.offset >= columns.count
        let separator = isFirstOrLast ? "" : ",\(spacer)"
        return partial + separator + entry.element
    }
}

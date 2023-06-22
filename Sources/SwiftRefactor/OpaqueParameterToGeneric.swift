//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2023 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import SwiftSyntax

/// Describes a "some" parameter that has been rewritten into a generic
/// parameter.
fileprivate struct RewrittenSome {
  let original: ConstrainedSugarTypeSyntax
  let genericParam: GenericParameterSyntax
  let genericParamRef: SimpleTypeIdentifierSyntax
}

/// Rewrite `some` parameters to explicit generic parameters.
///
/// ## Before
///
/// ```swift
/// func someFunction(_ input: some Value) {}
/// ```
///
/// ## After
///
/// ```swift
/// func someFunction<T1: Value>(_ input: T1) {}
/// ```
fileprivate class SomeParameterRewriter: SyntaxRewriter {
  var rewrittenSomeParameters: [RewrittenSome] = []

  override func visit(_ node: ConstrainedSugarTypeSyntax) -> TypeSyntax {
    if node.someOrAnySpecifier.text != "some" {
      return TypeSyntax(node)
    }

    let paramName = "T\(rewrittenSomeParameters.count + 1)"
    let paramNameSyntax = TokenSyntax.identifier(paramName)

    let inheritedType: TypeSyntax?
    let colon: TokenSyntax?
    if node.baseType.description != "Any" {
      colon = .colonToken()
      inheritedType = node.baseType.with(\.leadingTrivia, .space)
    } else {
      colon = nil
      inheritedType = nil
    }

    let genericParam = GenericParameterSyntax(
      attributes: nil,
      each: nil,
      name: paramNameSyntax,
      colon: colon,
      inheritedType: inheritedType,
      trailingComma: nil
    )

    let genericParamRef = SimpleTypeIdentifierSyntax(
      name: .identifier(paramName),
      genericArgumentClause: nil
    )

    rewrittenSomeParameters.append(
      .init(
        original: node,
        genericParam: genericParam,
        genericParamRef: genericParamRef
      )
    )

    return TypeSyntax(genericParamRef)
  }

  override func visit(_ node: TupleTypeSyntax) -> TypeSyntax {
    let newNode = super.visit(node)

    // If this tuple type is simple parentheses around a replaced "some"
    // parameter, drop the parentheses.
    guard let newTuple = newNode.as(TupleTypeSyntax.self),
      newTuple.elements.count == 1,
      let onlyElement = newTuple.elements.first,
      onlyElement.name == nil,
      onlyElement.ellipsis == nil,
      let onlyIdentifierType =
        onlyElement.type.as(SimpleTypeIdentifierSyntax.self),
      rewrittenSomeParameters.first(
        where: { $0.genericParamRef.name.text == onlyIdentifierType.name.text }
      ) != nil
    else {
      return newNode
    }

    return TypeSyntax(onlyIdentifierType)
  }
}

/// Rewrite `some` parameters to explicit generic parameters.
///
/// ## Before
///
/// ```swift
/// func someFunction(_ input: some Value) {}
/// ```
///
/// ## After
///
/// ```swift
/// func someFunction<T1: Value>(_ input: T1) {}
/// ```
public struct OpaqueParameterToGeneric: SyntaxRefactoringProvider {
  /// Replace all of the "some" parameters in the given parameter clause with
  /// freshly-created generic parameters.
  ///
  /// - Returns: nil if there was nothing to rewrite, or a pair of the
  /// rewritten parameters and augmented generic parameter list.
  static func replaceSomeParameters(
    in params: ParameterClauseSyntax,
    augmenting genericParams: GenericParameterClauseSyntax?
  ) -> (ParameterClauseSyntax, GenericParameterClauseSyntax)? {
    let rewriter = SomeParameterRewriter(viewMode: .sourceAccurate)
    let rewrittenParams = rewriter.visit(params.parameterList)

    if rewriter.rewrittenSomeParameters.isEmpty {
      return nil
    }

    var newGenericParams: [GenericParameterSyntax] = []
    if let genericParams {
      newGenericParams.append(contentsOf: genericParams.parameters)
    }

    for rewritten in rewriter.rewrittenSomeParameters {
      let newGenericParam = rewritten.genericParam

      // Add a trailing comma to the prior generic parameter, if there is one.
      if let lastNewGenericParam = newGenericParams.last {
        newGenericParams[newGenericParams.count - 1] =
          lastNewGenericParam.with(\.trailingComma, .commaToken())
        newGenericParams.append(newGenericParam.with(\.leadingTrivia, .space))
      } else {
        newGenericParams.append(newGenericParam)
      }
    }

    let newGenericParamSyntax = GenericParameterListSyntax(newGenericParams)
    let newGenericParamClause: GenericParameterClauseSyntax
    if let genericParams {
      newGenericParamClause = genericParams.with(
        \.parameters,
        newGenericParamSyntax
      )
    } else {
      newGenericParamClause = GenericParameterClauseSyntax(
        leftAngleBracket: .leftAngleToken(),
        parameters: newGenericParamSyntax,
        genericWhereClause: nil,
        rightAngleBracket: .rightAngleToken()
      )
    }

    return (
      params.with(\.parameterList, rewrittenParams),
      newGenericParamClause
    )
  }

  public static func refactor(
    syntax decl: DeclSyntax,
    in context: Void
  ) -> DeclSyntax? {
    // Function declaration.
    if let funcSyntax = decl.as(FunctionDeclSyntax.self) {
      guard
        let (newInput, newGenericParams) = replaceSomeParameters(
          in: funcSyntax.signature.input,
          augmenting: funcSyntax.genericParameterClause
        )
      else {
        return nil
      }

      return DeclSyntax(
        funcSyntax
          .with(\.signature, funcSyntax.signature.with(\.input, newInput))
          .with(\.genericParameterClause, newGenericParams)
      )
    }

    // Initializer declaration.
    if let initSyntax = decl.as(InitializerDeclSyntax.self) {
      guard
        let (newInput, newGenericParams) = replaceSomeParameters(
          in: initSyntax.signature.input,
          augmenting: initSyntax.genericParameterClause
        )
      else {
        return nil
      }

      return DeclSyntax(
        initSyntax
          .with(\.signature, initSyntax.signature.with(\.input, newInput))
          .with(\.genericParameterClause, newGenericParams)
      )
    }

    // Subscript declaration.
    if let subscriptSyntax = decl.as(SubscriptDeclSyntax.self) {
      guard
        let (newIndices, newGenericParams) = replaceSomeParameters(
          in: subscriptSyntax.indices,
          augmenting: subscriptSyntax.genericParameterClause
        )
      else {
        return nil
      }

      return DeclSyntax(
        subscriptSyntax
          .with(\.indices, newIndices)
          .with(\.genericParameterClause, newGenericParams)
      )
    }

    return nil
  }
}

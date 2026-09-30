import AppKit

// Syntax colors for fenced code blocks, keyed by the fence's language
// ("```swift"). Each language is one alternation regex whose branches are
// tried left to right, so comments and strings claim their text before
// keywords or numbers inside them can. Identifiers are classified after
// matching (keyword, literal, type, function call).

@MainActor
enum SyntaxHighlighter {
  enum Kind {
    case keyword, literal, string, comment, number, type, function, property, tag, meta, inserted, deleted, plainWord
  }

  private struct Grammar {
    var branches: [(pattern: String, kind: Kind)]
    var keywords: Set<String> = []
    var literals: Set<String> = []
    /// Capitalized identifiers are types (Swift, Java, Rust...).
    var capitalizedTypes = false
    var caseInsensitive = false
  }

  private final class Compiled {
    let regex: NSRegularExpression
    let kinds: [Kind]
    let grammar: Grammar
    init(_ grammar: Grammar) {
      self.grammar = grammar
      kinds = grammar.branches.map(\.kind)
      let pattern = grammar.branches.map { "(\($0.pattern))" }.joined(separator: "|")
      regex = try! NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
    }
  }

  private static var cache: [String: Compiled] = [:]

  /// Colors `range` of `storage`, a code block written in `language`.
  /// Unknown languages are left plain.
  static func highlight(_ storage: NSTextStorage, range: NSRange, language: String) {
    guard range.length > 0, let name = canonical(language) else { return }
    let compiled: Compiled
    if let cached = cache[name] {
      compiled = cached
    } else if let grammar = grammar(for: name) {
      compiled = Compiled(grammar)
      cache[name] = compiled
    } else {
      return
    }
    let string = storage.string as NSString
    let grammar = compiled.grammar
    for match in compiled.regex.matches(in: storage.string, range: range) {
      guard let group = (1...compiled.kinds.count).first(where: { match.range(at: $0).location != NSNotFound }) else { continue }
      let matched = match.range(at: group)
      guard matched.length > 0 else { continue }
      var kind = compiled.kinds[group - 1]
      if kind == .plainWord {
        let word = string.substring(with: matched)
        let key = grammar.caseInsensitive ? word.lowercased() : word
        if grammar.keywords.contains(key) {
          kind = .keyword
        } else if grammar.literals.contains(key) {
          kind = .literal
        } else if grammar.capitalizedTypes, let first = word.unicodeScalars.first, CharacterSet.uppercaseLetters.contains(first) {
          kind = .type
        } else if nextNonSpace(string, after: NSMaxRange(matched), limit: NSMaxRange(range)) == 0x28 {  // "("
          kind = .function
        } else {
          continue
        }
      }
      storage.addAttribute(.foregroundColor, value: color(kind), range: matched)
    }
  }

  private static func nextNonSpace(_ string: NSString, after index: Int, limit: Int) -> unichar? {
    var i = index
    while i < limit {
      let c = string.character(at: i)
      if c != 0x20 && c != 0x09 { return c }
      i += 1
    }
    return nil
  }

  private static func color(_ kind: Kind) -> NSColor {
    switch kind {
    case .keyword: Theme.Syntax.keyword
    case .literal, .number: Theme.Syntax.number
    case .string: Theme.Syntax.string
    case .comment: Theme.Syntax.comment
    case .type: Theme.Syntax.type
    case .function, .meta: Theme.Syntax.function
    case .property: Theme.Syntax.property
    case .tag, .inserted: Theme.Syntax.tag
    case .deleted: Theme.Syntax.deleted
    case .plainWord: Theme.text
    }
  }

  // MARK: - Languages

  private static func canonical(_ language: String) -> String? {
    switch language.lowercased() {
    case "swift": "swift"
    case "js", "javascript", "jsx", "mjs", "cjs", "ts", "typescript", "tsx": "js"
    case "json", "jsonc", "json5": "json"
    case "py", "python", "python3": "python"
    case "rs", "rust": "rust"
    case "go", "golang": "go"
    case "c", "h", "cpp", "c++", "cc", "hpp", "cxx", "objc", "objective-c", "objectivec", "mm", "objcpp", "objective-c++": "c"
    case "java", "kotlin", "kt", "kts", "cs", "csharp", "c#", "scala", "dart": "java"
    case "rb", "ruby": "ruby"
    case "sh", "bash", "zsh", "shell", "console", "fish": "shell"
    case "sql", "postgres", "postgresql", "mysql", "sqlite": "sql"
    case "css", "scss", "sass", "less": "css"
    case "html", "xml", "svg", "xhtml", "plist", "vue": "html"
    case "yaml", "yml": "yaml"
    case "toml", "ini", "conf": "toml"
    case "diff", "patch": "diff"
    case "php": "php"
    case "lua": "lua"
    default: nil
    }
  }

  // Shared branches.
  private static let blockComment = (#"/\*[\s\S]*?(?:\*/|\z)"#, Kind.comment)
  private static let slashComment = (#"//.*"#, Kind.comment)
  private static let hashComment = (#"(?<![\w$])#.*"#, Kind.comment)
  private static let doubleString = (#""(?:[^"\\\n]|\\.)*"?"#, Kind.string)
  private static let singleString = (#"'(?:[^'\\\n]|\\.)*'?"#, Kind.string)
  private static let tripleString = (#""""[\s\S]*?(?:"""|\z)"#, Kind.string)
  private static let number = (#"\b(?:0[xX][0-9a-fA-F_]+|0[bB][01_]+|0[oO][0-7_]+|\d[\d_]*(?:\.\d[\d_]*)?(?:[eE][+-]?\d+)?)\b"#, Kind.number)
  private static let word = (#"\b[A-Za-z_][\w]*\b"#, Kind.plainWord)

  private static func grammar(for name: String) -> Grammar? {
    switch name {
    case "swift":
      return Grammar(
        branches: [blockComment, slashComment, tripleString, doubleString, (#"@\w+"#, .meta), (#"#\w+"#, .meta), number, word],
        keywords: ["actor", "any", "as", "associatedtype", "async", "await", "break", "case", "catch", "class", "continue",
                   "convenience", "default", "defer", "deinit", "didSet", "do", "dynamic", "else", "enum", "extension",
                   "fallthrough", "fileprivate", "final", "for", "func", "get", "guard", "if", "import", "in", "indirect",
                   "init", "inout", "internal", "is", "isolated", "lazy", "let", "mutating", "nonisolated", "nonmutating",
                   "open", "operator", "optional", "override", "private", "protocol", "public", "repeat", "required",
                   "rethrows", "return", "set", "some", "static", "struct", "subscript", "super", "switch", "throw",
                   "throws", "try", "typealias", "unowned", "var", "weak", "where", "while", "willSet", "self", "Self"],
        literals: ["true", "false", "nil"],
        capitalizedTypes: true)
    case "js":
      return Grammar(
        branches: [blockComment, slashComment, doubleString, singleString, (#"`(?:[^`\\]|\\[\s\S])*`?"#, .string),
                   (#"@\w+"#, .meta), number, (#"\b[A-Za-z_$][\w$]*\b"#, .plainWord)],
        keywords: ["abstract", "as", "async", "await", "break", "case", "catch", "class", "const", "continue", "debugger",
                   "declare", "default", "delete", "do", "else", "enum", "export", "extends", "finally", "for", "from",
                   "function", "get", "if", "implements", "import", "in", "instanceof", "interface", "keyof", "let",
                   "namespace", "new", "of", "private", "protected", "public", "readonly", "return", "satisfies", "set",
                   "static", "super", "switch", "this", "throw", "try", "type", "typeof", "var", "void", "while", "with",
                   "yield"],
        literals: ["true", "false", "null", "undefined", "NaN", "Infinity"],
        capitalizedTypes: true)
    case "json":
      return Grammar(
        branches: [blockComment, slashComment, (#""(?:[^"\\\n]|\\.)*"(?=\s*:)"#, .property), doubleString, number, word],
        literals: ["true", "false", "null"])
    case "python":
      return Grammar(
        branches: [hashComment, (#"[rRbBfFuU]{0,2}(?:"""[\s\S]*?(?:"""|\z)|'''[\s\S]*?(?:'''|\z))"#, .string),
                   (#"[rRbBfFuU]{0,2}(?:"(?:[^"\\\n]|\\.)*"?|'(?:[^'\\\n]|\\.)*'?)"#, .string),
                   (#"^\s*@[\w.]+"#, .meta), number, word],
        keywords: ["and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del", "elif", "else",
                   "except", "finally", "for", "from", "global", "if", "import", "in", "is", "lambda", "match", "case",
                   "nonlocal", "not", "or", "pass", "raise", "return", "try", "while", "with", "yield", "self", "cls"],
        literals: ["True", "False", "None"],
        capitalizedTypes: true)
    case "rust":
      return Grammar(
        branches: [blockComment, slashComment, doubleString, (#"'(?:[^'\\\n]|\\.)'"#, .string), (#"#!?\[[^\]\n]*\]"#, .meta),
                   (#"\b\w+!"#, .meta), (#"'\w+"#, .meta), number, word],
        keywords: ["as", "async", "await", "break", "const", "continue", "crate", "dyn", "else", "enum", "extern", "fn",
                   "for", "if", "impl", "in", "let", "loop", "match", "mod", "move", "mut", "pub", "ref", "return", "self",
                   "Self", "static", "struct", "super", "trait", "type", "unsafe", "use", "where", "while"],
        literals: ["true", "false"],
        capitalizedTypes: true)
    case "go":
      return Grammar(
        branches: [blockComment, slashComment, doubleString, singleString, (#"`[^`]*`?"#, .string), number, word],
        keywords: ["break", "case", "chan", "const", "continue", "default", "defer", "else", "fallthrough", "for", "func",
                   "go", "goto", "if", "import", "interface", "map", "package", "range", "return", "select", "struct",
                   "switch", "type", "var", "string", "int", "int64", "int32", "uint", "byte", "rune", "bool", "error",
                   "float64", "float32", "any"],
        literals: ["true", "false", "nil", "iota"],
        capitalizedTypes: false)
    case "c":
      return Grammar(
        branches: [blockComment, slashComment, (#"^\s*#\s*\w+"#, .meta), (#"@?"(?:[^"\\\n]|\\.)*"?"#, .string),
                   (#"'(?:[^'\\\n]|\\.)*'?"#, .string), (#"@\w+"#, .keyword), number, word],
        keywords: ["auto", "break", "case", "char", "class", "const", "constexpr", "continue", "default", "delete", "do",
                   "double", "else", "enum", "explicit", "extern", "float", "for", "friend", "goto", "if", "inline",
                   "int", "long", "mutable", "namespace", "new", "noexcept", "operator", "override", "private",
                   "protected", "public", "register", "return", "short", "signed", "sizeof", "static", "struct",
                   "switch", "template", "this", "throw", "try", "catch", "typedef", "typename", "union", "unsigned",
                   "using", "virtual", "void", "volatile", "while", "bool", "self", "id", "instancetype", "BOOL"],
        literals: ["true", "false", "NULL", "nullptr", "nil", "YES", "NO"],
        capitalizedTypes: true)
    case "java":
      return Grammar(
        branches: [blockComment, slashComment, tripleString, doubleString, singleString, (#"@\w+"#, .meta), number, word],
        keywords: ["abstract", "as", "async", "await", "base", "boolean", "break", "byte", "case", "catch", "char", "class",
                   "companion", "const", "continue", "data", "default", "do", "double", "else", "enum", "extends",
                   "final", "finally", "float", "for", "fun", "if", "implements", "import", "in", "init", "int",
                   "interface", "internal", "is", "late", "long", "namespace", "new", "object", "open", "override",
                   "package", "private", "protected", "public", "readonly", "return", "sealed", "short", "static",
                   "string", "super", "switch", "synchronized", "this", "throw", "throws", "try", "typealias", "using",
                   "val", "var", "void", "when", "while", "yield"],
        literals: ["true", "false", "null"],
        capitalizedTypes: true)
    case "ruby":
      return Grammar(
        branches: [hashComment, doubleString, singleString, (#":\w+"#, .literal), (#"@{1,2}\w+"#, .property), number, word],
        keywords: ["alias", "and", "begin", "break", "case", "class", "def", "defined?", "do", "else", "elsif", "end",
                   "ensure", "for", "if", "in", "module", "next", "not", "or", "redo", "rescue", "retry", "return",
                   "self", "super", "then", "undef", "unless", "until", "when", "while", "yield", "require", "attr_reader",
                   "attr_accessor", "puts"],
        literals: ["true", "false", "nil"],
        capitalizedTypes: true)
    case "shell":
      return Grammar(
        branches: [hashComment, doubleString, (#"'[^']*'?"#, .string), (#"\$\{[^}\n]*\}?|\$[\w@#?*!$-]"#, .property),
                   (#"(?<=\s|^)--?[\w-]+"#, .meta), number, (#"\b[\w-]+\b"#, .plainWord)],
        keywords: ["if", "then", "else", "elif", "fi", "for", "while", "until", "do", "done", "case", "esac", "in",
                   "function", "return", "export", "local", "readonly", "set", "unset", "source", "exit", "shift",
                   "echo", "cd", "sudo", "exec", "eval", "trap"])
    case "sql":
      return Grammar(
        branches: [blockComment, (#"--.*"#, .comment), singleString, doubleString, number, word],
        keywords: ["select", "from", "where", "and", "or", "not", "insert", "into", "values", "update", "set", "delete",
                   "create", "table", "index", "view", "drop", "alter", "add", "column", "primary", "key", "foreign",
                   "references", "join", "inner", "left", "right", "outer", "full", "cross", "on", "as", "group", "by",
                   "order", "having", "limit", "offset", "union", "all", "distinct", "case", "when", "then", "else",
                   "end", "in", "is", "like", "between", "exists", "default", "unique", "constraint", "with", "returning",
                   "asc", "desc", "integer", "int", "text", "varchar", "boolean", "timestamp", "real", "blob", "begin",
                   "commit", "rollback", "transaction", "if", "count", "sum", "avg", "min", "max"],
        literals: ["null", "true", "false"],
        caseInsensitive: true)
    case "css":
      return Grammar(
        branches: [blockComment, slashComment, doubleString, singleString, (#"@[\w-]+"#, .keyword),
                   (#"#[0-9a-fA-F]{3,8}\b"#, .number), (#"(?<![\w-])-?\d*\.?\d+(?:%|[a-zA-Z]+)?"#, .number),
                   (#"[\w-]+(?=\s*:[^:{};]*;)|--[\w-]+"#, .property), (#"[.#][\w-]+"#, .type), (#"!important"#, .keyword),
                   (#"\b[\w-]+(?=\()"#, .function)])
    case "html":
      return Grammar(
        branches: [(#"<!--[\s\S]*?(?:-->|\z)"#, .comment), (#"<!\w+[^>]*>?"#, .meta), (#"(?<=</|<)[\w:.-]+"#, .tag),
                   (#"[\w:.-]+(?==)"#, .property), (#"(?<==)(?:"[^"]*"?|'[^']*'?)"#, .string), (#"&\w+;|&#\w+;"#, .literal)])
    case "yaml":
      return Grammar(
        branches: [hashComment, (#"^\s*(?:-\s+)?[\w.\-/ ]+?(?=\s*:(?:\s|$))"#, .property), doubleString, singleString,
                   (#"^\s*---\s*$|[&*][\w-]+"#, .meta), number, word],
        literals: ["true", "false", "null", "yes", "no", "on", "off", "~"])
    case "toml":
      return Grammar(
        branches: [hashComment, (#";.*"#, .comment), (#"^\s*\[\[?[^\]\n]*\]\]?"#, .type),
                   (#"^\s*[\w.\-"]+(?=\s*=)"#, .property), tripleString, doubleString, singleString, number, word],
        literals: ["true", "false"])
    case "diff":
      return Grammar(
        branches: [(#"^(?:\+\+\+|---|diff |index ).*"#, .meta), (#"^@@.*"#, .function), (#"^\+.*"#, .inserted),
                   (#"^-.*"#, .deleted)])
    case "php":
      return Grammar(
        branches: [blockComment, slashComment, hashComment, doubleString, singleString, (#"\$\w+"#, .property),
                   (#"<\?php|\?>"#, .meta), number, word],
        keywords: ["abstract", "and", "array", "as", "break", "case", "catch", "class", "const", "continue", "default",
                   "do", "echo", "else", "elseif", "extends", "final", "finally", "fn", "for", "foreach", "function",
                   "global", "if", "implements", "include", "interface", "match", "namespace", "new", "or", "private",
                   "protected", "public", "require", "return", "static", "switch", "throw", "trait", "try", "use",
                   "while", "yield"],
        literals: ["true", "false", "null"],
        capitalizedTypes: true)
    case "lua":
      return Grammar(
        branches: [(#"--\[\[[\s\S]*?(?:\]\]|\z)"#, .comment), (#"--.*"#, .comment), doubleString, singleString,
                   (#"\[\[[\s\S]*?(?:\]\]|\z)"#, .string), number, word],
        keywords: ["and", "break", "do", "else", "elseif", "end", "for", "function", "goto", "if", "in", "local", "not",
                   "or", "repeat", "return", "then", "until", "while"],
        literals: ["true", "false", "nil"])
    default:
      return nil
    }
  }
}

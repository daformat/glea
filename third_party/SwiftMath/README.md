SwiftMath (https://github.com/mgriebling/SwiftMath), MIT licensed, at commit
1d2c90827e9c3908269d810d055fb03b7da5fd53. Vendored for Glea's LaTeX math in notes:
its sources plus, in Sources/Glea, Bundle+Module.swift (stands in for the
Swift Package Manager's resource bundle) and MathHitTest.swift (maps a click
on a typeset formula to its place in the LaTeX).

Changes to SwiftMath's own sources, marked "(Glea)": MTMathAtom gains a
`sourceRange` (set by MTMathListBuilder for each atom, kept by copies and
fusing), which MathHitTest uses. Only the Latin Modern Math font
(GUST Font License) is kept from mathFonts.bundle.

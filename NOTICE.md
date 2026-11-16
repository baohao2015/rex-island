# Third-party notices

Rex Island borrows ideas and some code from these MIT-licensed projects.

## Pip (github.com/Kikatsu/pip-notch)

Adapted code: the eye drawing (`Sources/App/Views/Eyes.swift`), the notch panel, geometry and
shape (`Sources/App/Notch/NotchPanel.swift`), and the pointer-polling approach in
`NotchController`. Also the idea of wrapping Claude Code's status line to read plan limits, and
of reading Codex limits from its session logs.

```
MIT License

Copyright (c) 2026 Kikatsu

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## CodeIsland (github.com/wxtsky/CodeIsland)

No code copied. Learned from it: answers to `AskUserQuestion` must be keyed by question text and
keep `questions` in `updatedInput`; reading the Claude Code login for plan limits is possible but
Rex Island deliberately uses the status line instead, so it never touches credentials.

## Rex Radar, rex-inbox (github.com/hecspc/rex-radar, github.com/captjt/rex-inbox)

No code copied. Their notes on Rex's Program Status Protocol and on pressing a menu option only
after re-checking the pane informed `pressMenuOption`.

; inherits: markdown

; Chat role headers — matched on paragraph-level inline nodes.
; These only fire for visible lines (treesitter is viewport-based).
((inline) @CopilotAgentUser
  (#eq? @CopilotAgentUser "User:"))

((inline) @CopilotAgentAssistant
  (#eq? @CopilotAgentAssistant "Assistant:"))

((inline) @CopilotAgentDone
  (#match? @CopilotAgentDone "^\\s*Done\\.$"))

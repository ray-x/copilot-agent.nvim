package main

// LSP server mode (--lsp flag).
//
// Implements a minimal Language Server Protocol server over stdio that
// exposes Copilot code actions (Explain, Fix, Add tests, Add docs) for
// any file range. When the user selects an action Neovim calls
// workspace/executeCommand which builds a prompt from the selected code
// and sends it to the Copilot session via the shared HTTP service.

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"strings"
	"sync"
)

// ── LSP wire types ────────────────────────────────────────────────────────────

type lspMessage struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      any             `json:"id,omitempty"`
	Method  string          `json:"method,omitempty"`
	Params  json.RawMessage `json:"params,omitempty"`
	Result  any             `json:"result,omitempty"`
	Error   *lspError       `json:"error,omitempty"`
}

type lspError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

type lspPosition struct {
	Line      int `json:"line"`
	Character int `json:"character"`
}

type lspRange struct {
	Start lspPosition `json:"start"`
	End   lspPosition `json:"end"`
}

type lspTextDocumentIdentifier struct {
	URI string `json:"uri"`
}

type lspCodeActionParams struct {
	TextDocument lspTextDocumentIdentifier `json:"textDocument"`
	Range        lspRange                  `json:"range"`
	Context      struct {
		Diagnostics []json.RawMessage `json:"diagnostics"`
	} `json:"context"`
}

type lspCommand struct {
	Title     string `json:"title"`
	Command   string `json:"command"`
	Arguments []any  `json:"arguments,omitempty"`
}

type lspCodeAction struct {
	Title   string      `json:"title"`
	Kind    string      `json:"kind"`
	Command *lspCommand `json:"command,omitempty"`
}

type lspExecuteCommandParams struct {
	Command   string            `json:"command"`
	Arguments []json.RawMessage `json:"arguments,omitempty"`
}

// lspCodeActionArg is passed as the single argument to workspace/executeCommand.
type lspCodeActionArg struct {
	Action       string   `json:"action"`
	URI          string   `json:"uri"`
	Range        lspRange `json:"range"`
	SelectedText string   `json:"selectedText"`
	ServiceURL   string   `json:"serviceURL"`
	SessionID    string   `json:"sessionId"`
}

// ── Code actions ─────────────────────────────────────────────────────────────

type codeActionDef struct {
	title  string
	kind   string
	action string
	prompt func(code, filename string) string
}

var codeActions = []codeActionDef{
	{
		title:  "Copilot: Explain code",
		kind:   "source",
		action: "explain",
		prompt: func(code, filename string) string {
			return fmt.Sprintf("Explain the following code from `%s`:\n\n```\n%s\n```", filename, code)
		},
	},
	{
		title:  "Copilot: Fix code",
		kind:   "quickfix",
		action: "fix",
		prompt: func(code, filename string) string {
			return fmt.Sprintf("Fix any bugs or issues in the following code from `%s`. Show the corrected version and explain what was wrong:\n\n```\n%s\n```", filename, code)
		},
	},
	{
		title:  "Copilot: Add tests",
		kind:   "source",
		action: "add_tests",
		prompt: func(code, filename string) string {
			return fmt.Sprintf("Write unit tests for the following code from `%s`:\n\n```\n%s\n```", filename, code)
		},
	},
	{
		title:  "Copilot: Add docs",
		kind:   "source",
		action: "add_docs",
		prompt: func(code, filename string) string {
			return fmt.Sprintf("Add documentation comments to the following code from `%s`. Return the fully documented version:\n\n```\n%s\n```", filename, code)
		},
	},
}

// ── LSP server ────────────────────────────────────────────────────────────────

type lspServer struct {
	serviceURL string // base URL of the HTTP service
	mu         sync.Mutex
	sessionID  string // session to send messages to (resolved lazily); guarded by mu
	reader     *bufio.Reader
	writer     io.Writer
}

func runLSPServer(ctx context.Context, serviceURL string) error {
	srv := &lspServer{
		serviceURL: serviceURL,
		reader:     bufio.NewReader(os.Stdin),
		writer:     os.Stdout,
	}
	return srv.serve(ctx)
}

func (s *lspServer) serve(ctx context.Context) error {
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		default:
		}

		msg, err := s.readMessage()
		if err != nil {
			if err == io.EOF {
				return nil
			}
			return fmt.Errorf("read LSP message: %w", err)
		}

		go s.handleMessage(ctx, msg)
	}
}

func (s *lspServer) readMessage() (*lspMessage, error) {
	// Read headers
	var contentLength int
	for {
		line, err := s.reader.ReadString('\n')
		if err != nil {
			return nil, err
		}
		line = strings.TrimRight(line, "\r\n")
		if line == "" {
			break
		}
		if strings.HasPrefix(line, "Content-Length: ") {
			n, err := strconv.Atoi(strings.TrimPrefix(line, "Content-Length: "))
			if err != nil {
				return nil, fmt.Errorf("invalid Content-Length: %w", err)
			}
			contentLength = n
		}
	}

	if contentLength == 0 {
		return nil, fmt.Errorf("missing Content-Length header")
	}

	body := make([]byte, contentLength)
	if _, err := io.ReadFull(s.reader, body); err != nil {
		return nil, fmt.Errorf("read LSP body: %w", err)
	}

	var msg lspMessage
	if err := json.Unmarshal(body, &msg); err != nil {
		return nil, fmt.Errorf("unmarshal LSP message: %w", err)
	}
	return &msg, nil
}

func (s *lspServer) send(msg lspMessage) {
	msg.JSONRPC = "2.0"
	data, err := json.Marshal(msg)
	if err != nil {
		log.Printf("lsp: marshal response: %v", err)
		return
	}
	payload := fmt.Sprintf("Content-Length: %d\r\n\r\n%s", len(data), data)
	if _, err := fmt.Fprint(s.writer, payload); err != nil {
		log.Printf("lsp: write response: %v", err)
	}
}

func (s *lspServer) reply(id any, result any) {
	s.send(lspMessage{ID: id, Result: result})
}

func (s *lspServer) replyError(id any, code int, message string) {
	s.send(lspMessage{ID: id, Error: &lspError{Code: code, Message: message}})
}

func (s *lspServer) handleMessage(ctx context.Context, msg *lspMessage) {
	switch msg.Method {
	case "initialize":
		s.reply(msg.ID, map[string]any{
			"capabilities": map[string]any{
				"codeActionProvider": map[string]any{
					"codeActionKinds": []string{"quickfix", "source"},
					"resolveProvider": false,
				},
				"executeCommandProvider": map[string]any{
					"commands": []string{
						"copilot.explain",
						"copilot.fix",
						"copilot.add_tests",
						"copilot.add_docs",
					},
				},
			},
			"serverInfo": map[string]any{
				"name":    "copilot-agent-lsp",
				"version": "0.1.0",
			},
		})

	case "initialized":
		// No-op — notification, no reply.

	case "shutdown":
		s.reply(msg.ID, nil)

	case "exit":
		os.Exit(0)

	case "textDocument/codeAction":
		s.handleCodeAction(ctx, msg)

	case "workspace/executeCommand":
		s.handleExecuteCommand(ctx, msg)

	default:
		if msg.ID != nil {
			s.replyError(msg.ID, -32601, fmt.Sprintf("method not found: %s", msg.Method))
		}
	}
}

func (s *lspServer) handleCodeAction(_ context.Context, msg *lspMessage) {
	var params lspCodeActionParams
	if err := json.Unmarshal(msg.Params, &params); err != nil {
		s.replyError(msg.ID, -32602, "invalid params")
		return
	}

	filename := uriToFilename(params.TextDocument.URI)
	s.mu.Lock()
	cachedSessionID := s.sessionID
	s.mu.Unlock()
	actions := make([]lspCodeAction, 0, len(codeActions))
	for _, def := range codeActions {
		arg := lspCodeActionArg{
			Action:     def.action,
			URI:        params.TextDocument.URI,
			Range:      params.Range,
			ServiceURL: s.serviceURL,
			SessionID:  cachedSessionID,
		}
		actions = append(actions, lspCodeAction{
			Title: def.title,
			Kind:  def.kind,
			Command: &lspCommand{
				Title:     def.title,
				Command:   "copilot." + def.action,
				Arguments: []any{arg, filename},
			},
		})
	}
	s.reply(msg.ID, actions)
}

func (s *lspServer) handleExecuteCommand(ctx context.Context, msg *lspMessage) {
	var params lspExecuteCommandParams
	if err := json.Unmarshal(msg.Params, &params); err != nil {
		s.replyError(msg.ID, -32602, "invalid params")
		return
	}

	if len(params.Arguments) < 2 {
		s.replyError(msg.ID, -32602, "expected 2 arguments: actionArg, filename")
		return
	}

	var arg lspCodeActionArg
	if err := json.Unmarshal(params.Arguments[0], &arg); err != nil {
		s.replyError(msg.ID, -32602, fmt.Sprintf("invalid action argument: %v", err))
		return
	}

	var filename string
	if err := json.Unmarshal(params.Arguments[1], &filename); err != nil {
		filename = uriToFilename(arg.URI)
	}

	// Find the matching action definition.
	var def *codeActionDef
	for i := range codeActions {
		if codeActions[i].action == arg.Action {
			def = &codeActions[i]
			break
		}
	}
	if def == nil {
		s.replyError(msg.ID, -32602, fmt.Sprintf("unknown action: %s", arg.Action))
		return
	}

	// Read the selected lines from the file.
	code := readFileRange(filename, arg.Range)
	prompt := def.prompt(code, filename)

	// Resolve which session to use.
	serviceURL := arg.ServiceURL
	if serviceURL == "" {
		serviceURL = s.serviceURL
	}
	sessionID := arg.SessionID
	if sessionID == "" {
		s.mu.Lock()
		sessionID = s.sessionID
		s.mu.Unlock()
	}
	if sessionID == "" {
		var err error
		sessionID, err = s.resolveActiveSession(ctx, serviceURL)
		if err != nil {
			s.replyError(msg.ID, -32603, fmt.Sprintf("no active Copilot session: %v", err))
			return
		}
		s.mu.Lock()
		s.sessionID = sessionID
		s.mu.Unlock()
	}

	// Send the prompt.
	if err := s.sendPrompt(ctx, serviceURL, sessionID, prompt); err != nil {
		s.replyError(msg.ID, -32603, fmt.Sprintf("send prompt: %v", err))
		return
	}

	s.reply(msg.ID, nil)
}

// resolveActiveSession picks the first live session from the HTTP service.
func (s *lspServer) resolveActiveSession(ctx context.Context, serviceURL string) (string, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, serviceURL+"/sessions", nil)
	if err != nil {
		return "", err
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()

	var body struct {
		Live []struct {
			SessionID string `json:"sessionId"`
		} `json:"live"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		return "", err
	}
	if len(body.Live) == 0 {
		return "", fmt.Errorf("no live sessions")
	}
	return body.Live[0].SessionID, nil
}

// sendPrompt POSTs a message to the session via the HTTP service.
func (s *lspServer) sendPrompt(ctx context.Context, serviceURL, sessionID, prompt string) error {
	body, err := json.Marshal(map[string]any{"prompt": prompt})
	if err != nil {
		return err
	}
	url := fmt.Sprintf("%s/sessions/%s/messages", serviceURL, sessionID)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 400 {
		var errBody struct {
			Error string `json:"error"`
		}
		_ = json.NewDecoder(resp.Body).Decode(&errBody)
		if errBody.Error != "" {
			return fmt.Errorf("HTTP %d: %s", resp.StatusCode, errBody.Error)
		}
		return fmt.Errorf("HTTP %d", resp.StatusCode)
	}
	return nil
}

// ── Helpers ───────────────────────────────────────────────────────────────────

func uriToFilename(uri string) string {
	uri = strings.TrimPrefix(uri, "file://")
	decoded, err := url.PathUnescape(uri)
	if err != nil {
		return uri
	}
	return decoded
}

// readFileRange reads lines [start.Line, end.Line] (0-based) from a file.
func readFileRange(filename string, r lspRange) string {
	f, err := os.Open(filename)
	if err != nil {
		return ""
	}
	defer f.Close()

	var lines []string
	scanner := bufio.NewScanner(f)
	lineNum := 0
	for scanner.Scan() {
		if lineNum >= r.Start.Line && lineNum <= r.End.Line {
			lines = append(lines, scanner.Text())
		}
		if lineNum > r.End.Line {
			break
		}
		lineNum++
	}
	return strings.Join(lines, "\n")
}

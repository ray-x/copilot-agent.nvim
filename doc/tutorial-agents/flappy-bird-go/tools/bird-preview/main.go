package main

import (
	"fmt"
	"os"
	"strings"

	"github.com/charmbracelet/lipgloss"
)

const (
	birdWidth  = 12
	birdHeight = 3
)

type frame [birdHeight][birdWidth]string

type renderer struct {
	useASCII bool
	skyBg    lipgloss.Color
	bodyBg   lipgloss.Color
	headBg   lipgloss.Color
	wingBg   lipgloss.Color
	tailBg   lipgloss.Color
	eyeBg    lipgloss.Color
	eyeFg    lipgloss.Color
	beakFg   lipgloss.Color
}

func main() {
	r := renderer{
		useASCII: os.Getenv("BIRD_PREVIEW_ASCII") == "1",
		skyBg:    lipgloss.Color("#87CEEB"),
		bodyBg:   lipgloss.Color("#D8AA00"),
		headBg:   lipgloss.Color("#F7F3E8"),
		wingBg:   lipgloss.Color("#FFFFFF"),
		tailBg:   lipgloss.Color("#6F4A12"),
		eyeBg:    lipgloss.Color("#FFFFFF"),
		eyeFg:    lipgloss.Color("#111111"),
		beakFg:   lipgloss.Color("#E85D75"),
	}

	poses := []struct {
		name  string
		frame frame
	}{
		{name: "WINGS UP  (ascending)", frame: wingsUp},
		{name: "WINGS MID (neutral)", frame: wingsMid},
		{name: "WINGS DOWN (descending)", frame: wingsDown},
	}

	skyPad := r.cell("scene") + r.cell("scene") + r.cell("scene") + r.cell("scene") + r.cell("scene") + r.cell("scene") + r.cell("scene") + r.cell("scene") + r.cell("scene") + r.cell("scene") + r.cell("scene") + r.cell("scene")
	fmt.Fprintln(os.Stdout)
	fmt.Println("  Bird preview: scene-sampled bg + solid torso/head")
	fmt.Println()
	if !r.useASCII {
		fmt.Println("  Unicode mode (set BIRD_PREVIEW_ASCII=1 for ASCII fallback)")
		fmt.Println()
	}
	for _, p := range poses {
		fmt.Printf("  %s\n", p.name)
		fmt.Println("  " + skyPad)
		for y := 0; y < birdHeight; y++ {
			fmt.Println("  " + r.renderRow(p.frame[y]))
		}
		fmt.Println("  " + skyPad)
		fmt.Println()
	}
}

func (r renderer) renderRow(row [birdWidth]string) string {
	var b strings.Builder
	for _, token := range row {
		b.WriteString(r.cell(token))
	}
	b.WriteString(r.style(" ", nil, &r.skyBg))
	b.WriteString(r.style(" ", nil, &r.skyBg))
	return b.String()
}

func (r renderer) cell(token string) string {
	switch token {
	case "scene":
		return r.style(" ", nil, &r.skyBg)
	case "B^":
		if r.useASCII {
			return r.style("#", &r.bodyBg, &r.skyBg)
		}
		return r.style("▄", &r.bodyBg, &r.skyBg)
	case "B ":
		return r.style(" ", nil, &r.bodyBg)
	case "Bv":
		if r.useASCII {
			return r.style("#", &r.bodyBg, &r.skyBg)
		}
		return r.style("▀", &r.bodyBg, &r.skyBg)
	case "Hb^":
		if r.useASCII {
			return r.style("@", &r.headBg, &r.skyBg)
		}
		return r.style("▟", &r.headBg, &r.skyBg)
	case "Hf^":
		if r.useASCII {
			return r.style("@", &r.headBg, &r.skyBg)
		}
		return r.style("▙", &r.headBg, &r.skyBg)
	case "H ":
		return r.style(" ", nil, &r.headBg)
	case "Hv":
		if r.useASCII {
			return r.style("@", &r.headBg, &r.skyBg)
		}
		return r.style("▀", &r.headBg, &r.skyBg)
	case "eye":
		glyph := "●"
		if r.useASCII {
			glyph = "o"
		}
		return r.style(glyph, &r.eyeFg, &r.eyeBg)
	case "bk":
		glyph := "▶"
		if r.useASCII {
			glyph = ">"
		}
		return r.style(glyph, &r.beakFg, &r.skyBg)
	case "Tail-square":
		return r.style(" ", nil, &r.tailBg)
	case "Tail-tri":
		glyph := "▜"
		if r.useASCII {
			glyph = "/"
		}
		return r.style(glyph, &r.tailBg, &r.skyBg)
	case "Wup-tri":
		glyph := "▟"
		if r.useASCII {
			glyph = "/"
		}
		return r.style(glyph, &r.wingBg, &r.skyBg)
	case "Wup-square", "Wmid-square", "Wdown-square":
		return r.style(" ", nil, &r.wingBg)
	case "Wmid-rect":
		glyph := "▐"
		if r.useASCII {
			glyph = "|"
		}
		return r.style(glyph, &r.wingBg, &r.skyBg)
	case "Wdown-tri":
		glyph := "▜"
		if r.useASCII {
			glyph = "\\"
		}
		return r.style(glyph, &r.wingBg, &r.skyBg)
	default:
		return r.style(" ", nil, &r.skyBg)
	}
}

func (r renderer) style(glyph string, fg, bg *lipgloss.Color) string {
	st := lipgloss.NewStyle()
	if fg != nil {
		st = st.Foreground(*fg)
	}
	if bg != nil {
		st = st.Background(*bg)
	}
	return st.Render(glyph)
}

var wingsUp = frame{
	{"scene", "scene", "scene", "scene", "Wup-tri", "Wup-square", "B^", "B^", "Hb^", "Hf^", "scene", "scene"},
	{"scene", "scene", "scene", "Wup-tri", "Wup-square", "Tail-square", "B ", "B ", "H ", "eye", "H ", "bk"},
	{"scene", "scene", "scene", "scene", "Tail-tri", "Bv", "Bv", "Bv", "Hv", "Hv", "scene", "scene"},
}

var wingsMid = frame{
	{"scene", "scene", "scene", "scene", "scene", "B^", "B^", "B^", "Hb^", "Hf^", "scene", "scene"},
	{"scene", "scene", "scene", "Wmid-rect", "Wmid-square", "Wmid-square", "B ", "B ", "H ", "eye", "H ", "bk"},
	{"scene", "scene", "scene", "scene", "Tail-tri", "Bv", "Bv", "Bv", "Hv", "Hv", "scene", "scene"},
}

var wingsDown = frame{
	{"scene", "scene", "scene", "scene", "scene", "B^", "B^", "B^", "Hb^", "Hf^", "scene", "scene"},
	{"scene", "scene", "scene", "Wdown-tri", "Wdown-square", "Tail-square", "B ", "B ", "H ", "eye", "H ", "bk"},
	{"scene", "scene", "scene", "scene", "Wdown-tri", "Tail-tri", "Bv", "Bv", "Hv", "Hv", "scene", "scene"},
}

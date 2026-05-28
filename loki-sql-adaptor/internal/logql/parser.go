package logql

import (
	"fmt"
	"strings"
	"unicode"
)

// Parse parses a LogQL query string into an AST.
// Supports the subset used by the MaaS Usage Dashboard.
func Parse(input string) (*Query, error) {
	p := &parser{input: strings.TrimSpace(input), pos: 0}
	q, err := p.parseQuery()
	if err != nil {
		return nil, fmt.Errorf("parse logql: %w", err)
	}
	return q, nil
}

type parser struct {
	input string
	pos   int
}

func (p *parser) parseQuery() (*Query, error) {
	p.skipWhitespace()

	// Parenthesized expression: (expr) possibly followed by / or other binop
	if p.peek() == '(' {
		// Could be a grouped expression like (sum(...) / sum(...))
		// Check if it's NOT a function call (function calls are word + paren)
		return p.parseParenOrBinOp()
	}

	// Check for vector aggregation: sum(...), sum by (...) (...), count(...)
	if p.peekWord() == "sum" || p.peekWord() == "count" {
		q, err := p.parseVectorAggregation()
		if err != nil {
			return nil, err
		}
		// Check for binary op after
		return p.maybeParseBinOp(q)
	}

	// Check for range aggregation: sum_over_time(...), count_over_time(...)
	if p.peekWord() == "sum_over_time" || p.peekWord() == "count_over_time" {
		ra, err := p.parseRangeAggregation()
		if err != nil {
			return nil, err
		}
		q := &Query{RangeAgg: ra}
		return p.maybeParseBinOp(q)
	}

	// Raw log query: {selectors} | filters...
	if p.peek() == '{' {
		sel, err := p.parseStreamSelector()
		if err != nil {
			return nil, err
		}
		filters, err := p.parseFilters()
		if err != nil {
			return nil, err
		}
		return &Query{Selector: sel, Filters: filters}, nil
	}

	return nil, fmt.Errorf("unexpected input at pos %d: %q", p.pos, p.remaining())
}

func (p *parser) parseParenOrBinOp() (*Query, error) {
	p.advance() // consume '('
	p.skipWhitespace()

	left, err := p.parseQuery()
	if err != nil {
		return nil, err
	}

	p.skipWhitespace()

	// Check for binary operator inside parens
	if p.peek() == '/' || p.peek() == '*' || p.peek() == '+' || p.peek() == '-' {
		op := string(p.peek())
		p.advance()
		p.skipWhitespace()

		right, err := p.parseQuery()
		if err != nil {
			return nil, fmt.Errorf("parsing right side of %s: %w", op, err)
		}

		p.skipWhitespace()
		if p.peek() == ')' {
			p.advance()
		}

		q := &Query{BinOp: &BinOp{Op: op, Left: left, Right: right}}

		// Handle "or vector(N)" suffix
		p.skipWhitespace()
		if strings.HasPrefix(p.remaining(), "or vector(") || strings.HasPrefix(p.remaining(), "or\nvector(") {
			p.pos = len(p.input)
		}

		return q, nil
	}

	// Just a parenthesized expression
	if p.peek() == ')' {
		p.advance()
	}

	// Handle "or vector(N)" suffix after paren
	p.skipWhitespace()
	if strings.HasPrefix(p.remaining(), "or vector(") || strings.HasPrefix(p.remaining(), "or\nvector(") {
		p.pos = len(p.input)
	}

	return p.maybeParseBinOp(left)
}

func (p *parser) maybeParseBinOp(left *Query) (*Query, error) {
	p.skipWhitespace()

	// Handle "or vector(N)" suffix
	if strings.HasPrefix(p.remaining(), "or vector(") || strings.HasPrefix(p.remaining(), "or\nvector(") {
		p.pos = len(p.input)
		return left, nil
	}

	// Check for binary operator
	if p.peek() == '/' || p.peek() == '*' || p.peek() == '+' || p.peek() == '-' {
		op := string(p.peek())
		p.advance()
		p.skipWhitespace()

		right, err := p.parseQuery()
		if err != nil {
			return nil, fmt.Errorf("parsing right side of %s: %w", op, err)
		}

		return &Query{BinOp: &BinOp{Op: op, Left: left, Right: right}}, nil
	}

	return left, nil
}

func (p *parser) parseVectorAggregation() (*Query, error) {
	op := p.readWord()
	p.skipWhitespace()

	var groupBy []string

	// Check for "by (label1, label2)"
	if p.peekWord() == "by" {
		p.readWord()
		p.skipWhitespace()
		var err error
		groupBy, err = p.parseGroupByLabels()
		if err != nil {
			return nil, err
		}
		p.skipWhitespace()
	}

	// Expect opening paren
	if p.peek() != '(' {
		return nil, fmt.Errorf("expected '(' after %s, got %q", op, string(p.peek()))
	}
	p.advance()
	p.skipWhitespace()

	// Parse inner query
	inner, err := p.parseQuery()
	if err != nil {
		return nil, fmt.Errorf("parsing inner query of %s: %w", op, err)
	}

	p.skipWhitespace()

	// Expect closing paren
	if p.peek() != ')' {
		return nil, fmt.Errorf("expected ')' to close %s, got %q at pos %d", op, string(p.peek()), p.pos)
	}
	p.advance()

	// Handle "or vector(0)" suffix (ignore it)
	p.skipWhitespace()
	if strings.HasPrefix(p.remaining(), "or vector(") {
		// Skip to end
		p.pos = len(p.input)
	}

	return &Query{
		VectorAgg: &VectorAggregation{
			Op:      op,
			GroupBy: groupBy,
			Inner:   inner,
		},
	}, nil
}

func (p *parser) parseGroupByLabels() ([]string, error) {
	if p.peek() != '(' {
		return nil, fmt.Errorf("expected '(' for group by labels")
	}
	p.advance()

	var labels []string
	for {
		p.skipWhitespace()
		if p.peek() == ')' {
			p.advance()
			return labels, nil
		}
		label := p.readIdentifier()
		if label == "" {
			return nil, fmt.Errorf("expected label name in group by")
		}
		labels = append(labels, label)
		p.skipWhitespace()
		if p.peek() == ',' {
			p.advance()
		}
	}
}

func (p *parser) parseRangeAggregation() (*RangeAggregation, error) {
	op := p.readWord()
	p.skipWhitespace()

	if p.peek() != '(' {
		return nil, fmt.Errorf("expected '(' after %s", op)
	}
	p.advance()
	p.skipWhitespace()

	// Parse stream selector
	sel, err := p.parseStreamSelector()
	if err != nil {
		return nil, err
	}

	// Parse pipeline filters and unwrap
	var filters []PipelineFilter
	var unwrap *UnwrapExpr

	for {
		p.skipWhitespace()
		if p.peek() != '|' {
			break
		}
		p.advance()
		p.skipWhitespace()

		if p.peekWord() == "unwrap" {
			p.readWord()
			p.skipWhitespace()
			field := p.readIdentifier()
			unwrap = &UnwrapExpr{Field: field}
		} else {
			f, err := p.parseOneFilter()
			if err != nil {
				return nil, err
			}
			filters = append(filters, f)
		}
	}

	// Parse range duration [...]
	p.skipWhitespace()
	if p.peek() != '[' {
		return nil, fmt.Errorf("expected '[' for range duration, got %q", string(p.peek()))
	}
	p.advance()
	duration := p.readUntil(']')
	if p.peek() != ']' {
		return nil, fmt.Errorf("expected ']' to close range duration")
	}
	p.advance()

	// Close the range aggregation paren
	p.skipWhitespace()
	if p.peek() == ')' {
		p.advance()
	}

	return &RangeAggregation{
		Op:       op,
		Selector: *sel,
		Filters:  filters,
		Unwrap:   unwrap,
		Duration: duration,
	}, nil
}

func (p *parser) parseStreamSelector() (*StreamSelector, error) {
	if p.peek() != '{' {
		return nil, fmt.Errorf("expected '{' for stream selector, got %q", string(p.peek()))
	}
	p.advance()

	var matchers []Matcher
	for {
		p.skipWhitespace()
		if p.peek() == '}' {
			p.advance()
			return &StreamSelector{Matchers: matchers}, nil
		}

		label := p.readIdentifier()
		if label == "" {
			return nil, fmt.Errorf("expected label name in stream selector")
		}

		p.skipWhitespace()
		op, err := p.readMatchOp()
		if err != nil {
			return nil, err
		}

		p.skipWhitespace()
		value, err := p.readQuotedString()
		if err != nil {
			return nil, err
		}

		matchers = append(matchers, Matcher{Label: label, Op: op, Value: value})

		p.skipWhitespace()
		if p.peek() == ',' {
			p.advance()
		}
	}
}

func (p *parser) parseFilters() ([]PipelineFilter, error) {
	var filters []PipelineFilter
	for {
		p.skipWhitespace()
		if p.peek() != '|' {
			break
		}
		p.advance()
		p.skipWhitespace()

		// Skip "unwrap" in raw queries
		if p.peekWord() == "unwrap" {
			p.readWord()
			p.skipWhitespace()
			p.readIdentifier()
			continue
		}

		f, err := p.parseOneFilter()
		if err != nil {
			return nil, err
		}
		filters = append(filters, f)
	}
	return filters, nil
}

func (p *parser) parseOneFilter() (PipelineFilter, error) {
	label := p.readIdentifier()
	if label == "" {
		return PipelineFilter{}, fmt.Errorf("expected label name in filter at pos %d", p.pos)
	}

	p.skipWhitespace()
	op, err := p.readMatchOp()
	if err != nil {
		return PipelineFilter{}, err
	}

	p.skipWhitespace()
	value, err := p.readQuotedString()
	if err != nil {
		return PipelineFilter{}, err
	}

	return PipelineFilter{Label: label, Op: op, Value: value}, nil
}

func (p *parser) readMatchOp() (MatchOp, error) {
	if p.pos >= len(p.input) {
		return 0, fmt.Errorf("unexpected end of input reading match op")
	}

	switch {
	case strings.HasPrefix(p.input[p.pos:], "=~"):
		p.pos += 2
		return MatchRegexp, nil
	case strings.HasPrefix(p.input[p.pos:], "!~"):
		p.pos += 2
		return MatchNotRegexp, nil
	case strings.HasPrefix(p.input[p.pos:], "!="):
		p.pos += 2
		return MatchNotEqual, nil
	case p.input[p.pos] == '=':
		p.pos++
		return MatchEqual, nil
	default:
		return 0, fmt.Errorf("unexpected match operator at pos %d: %q", p.pos, p.input[p.pos:p.pos+2])
	}
}

func (p *parser) readQuotedString() (string, error) {
	if p.peek() != '"' {
		return "", fmt.Errorf("expected '\"' at pos %d, got %q", p.pos, string(p.peek()))
	}
	p.advance()

	var sb strings.Builder
	for p.pos < len(p.input) {
		ch := p.input[p.pos]
		if ch == '\\' && p.pos+1 < len(p.input) {
			p.pos++
			sb.WriteByte(p.input[p.pos])
			p.pos++
			continue
		}
		if ch == '"' {
			p.pos++
			return sb.String(), nil
		}
		sb.WriteByte(ch)
		p.pos++
	}
	return "", fmt.Errorf("unterminated string")
}

func (p *parser) readIdentifier() string {
	start := p.pos
	for p.pos < len(p.input) {
		ch := p.input[p.pos]
		if ch == '_' || ch == '.' || unicode.IsLetter(rune(ch)) || unicode.IsDigit(rune(ch)) {
			p.pos++
		} else {
			break
		}
	}
	return p.input[start:p.pos]
}

func (p *parser) readWord() string {
	start := p.pos
	for p.pos < len(p.input) {
		ch := p.input[p.pos]
		if ch == '_' || unicode.IsLetter(rune(ch)) || unicode.IsDigit(rune(ch)) {
			p.pos++
		} else {
			break
		}
	}
	return p.input[start:p.pos]
}

func (p *parser) peekWord() string {
	saved := p.pos
	w := p.readWord()
	p.pos = saved
	return w
}

func (p *parser) readUntil(ch byte) string {
	start := p.pos
	for p.pos < len(p.input) && p.input[p.pos] != ch {
		p.pos++
	}
	return p.input[start:p.pos]
}

func (p *parser) peek() byte {
	if p.pos >= len(p.input) {
		return 0
	}
	return p.input[p.pos]
}

func (p *parser) advance() {
	if p.pos < len(p.input) {
		p.pos++
	}
}

func (p *parser) skipWhitespace() {
	for p.pos < len(p.input) && (p.input[p.pos] == ' ' || p.input[p.pos] == '\t' || p.input[p.pos] == '\n' || p.input[p.pos] == '\r') {
		p.pos++
	}
}

func (p *parser) remaining() string {
	if p.pos >= len(p.input) {
		return ""
	}
	end := p.pos + 20
	if end > len(p.input) {
		end = len(p.input)
	}
	return p.input[p.pos:end]
}

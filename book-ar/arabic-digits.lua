-- arabic-digits.lua — Arabic edition digit handling for The Sourdough Framework
--
-- Original: The Sourdough Framework by Hendrik Kleinwächter,
-- the-sourdough-framework.com, CC BY-SA 4.0.
-- The Arabic edition inherits CC BY-SA 4.0.
--
-- Phase 28R reconstruction of the lost original, from the project record.
-- Two callbacks, both registered on post_linebreak_filter:
--
-- (1) digit_run_reversal: inside TRT (RTL) lines the bidi algorithm stores
--     bare Western-digit runs right-to-left, so "24" extracts and reads as
--     "42". This pass finds bare digit runs in TRT context and reverses
--     the node order so the digits read left-to-right. A run is digits
--     with . , : - between them (dotted numbers, times, ranges); the
--     separator set also includes Amiri's dot glyph U+121A0A; a single
--     trailing % or ° joins the run; untaken discretionary hyphens are
--     transparent. After reversing a segment the scan resumes at n.next.
--
--     Engine findings (LuaHBTeX 1.17.0, TeX Live 2023), kept here so they
--     are not re-derived: the base direction of a line rides the line
--     hlist's own dir field ("TRT"/"TLT"), while luabidi's run switches
--     are dir NODES carrying the signed forms "+TRT"/"-TRT"/"+TLT"/
--     "-TLT" (push/pop); a glyph node's character index is n.char, not
--     n.glyph. Known limitation, root-caused and closed in the record
--     2026-10-31 and reproduced here by design: the filter only sees
--     line-broken paragraphs, so content that never line-breaks (table
--     cells hpack LTR — correct as-is; hand-made \mbox/\hbox and TikZ
--     node interiors in RTL context) is not touched. Figure interiors
--     are LTR islands and the book's sources produce no such case.
--
-- (2) fontsplit remap: ASCII digits, letters and units punctuation that
--     land in Amiri are re-pointed to
--     size-matched TeX Gyre Pagella so Latin glyphs inside Arabic runs
--     match the book's Latin face. Size-matched via RATIO = 433/469,
--     style-matched (regular/bold/italic/bolditalic). Recurses into hlists
--     AND vlists.

local RATIO = 433 / 469

local DIGIT = {}
for c = string.byte("0"), string.byte("9") do DIGIT[c] = true end

local LETTER = {}
for c = string.byte("A"), string.byte("Z") do LETTER[c] = true end
for c = string.byte("a"), string.byte("z") do LETTER[c] = true end

-- separators allowed BETWEEN digits of a run
local SEPARATOR = {
  [0x2E]      = true,  -- .
  [0x2C]      = true,  -- ,
  [0x3A]      = true,  -- :
  [0x2D]      = true,  -- -
  [0x121A0A]  = true,  -- Amiri dot glyph
}

-- a single trailing one of these joins the run
local TRAILING = {
  [0x25] = true,  -- %
  [0xB0] = true,  -- °
}

-- ASCII remap set for the fontsplit pass: digits, letters, units punctuation
local REMAP = {}
for c = string.byte("0"), string.byte("9") do REMAP[c] = true end
for c = string.byte("A"), string.byte("Z") do REMAP[c] = true end
for c = string.byte("a"), string.byte("z") do REMAP[c] = true end
for _, c in ipairs({0x25, 0xB0, 0x28, 0x29, 0x2E, 0x2C, 0x2D, 0x3A,
                    0x2F, 0x2B, 0x3D, 0x20}) do
  REMAP[c] = true
end

-- ---------------------------------------------------------------- helpers

local fontcache = {}

-- unicode of a glyph node (first code of the character), or nil.
-- Lookup fallback: font.getfont returns an unpopulated table for fonts
-- defined directly through font.define (bypassing the define_font
-- callback), so font.fonts[fid] is the reliable table there.
local function node_code(n)
  local f = font.getfont(n.font)
  if not f or not f.characters then f = font.fonts[n.font] end
  if not f or not f.characters then return nil end
  local ch = f.characters[n.char]
  if not ch then return nil end
  local u = ch.unicode
  if type(u) == "table" then u = u[1] end
  return u
end

local function is_arabic_font(fid)
  local f = font.getfont(fid)
  if not f then return false end
  local name = (f.fullname or f.name or ""):lower()
  return name:find("amiri") and true or false
end

local function font_style(f)
  local name = (f.fullname or f.name or ""):lower()
  local bold = name:find("bold") and true or false
  local italic = (name:find("italic") or name:find("oblique")) and true or false
  if bold and italic then return "bolditalic"
  elseif bold then return "bold"
  elseif italic then return "italic"
  else return "regular" end
end

local PAGELLA_FILE = {
  regular    = "texgyrepagella-regular",
  bold       = "texgyrepagella-bold",
  italic     = "texgyrepagella-italic",
  bolditalic = "texgyrepagella-bolditalic",
}

-- load TeX Gyre Pagella at a scaled size, cached
local pagella_cache = {}
local function pagella_fid(size, style)
  local key = string.format("%d:%s", size, style)
  if pagella_cache[key] then return pagella_cache[key] end
  local fonts = fonts
  if not (fonts and fonts.definers and fonts.definers.read) then return nil end
  -- engine finding: fonts.definers.read takes the size as its SECOND
  -- argument; options in the spec string ("file:x.otf;size=...;mode=node")
  -- are not parsed by this luaotfload and break the file lookup. node
  -- mode is the luaotfload default, so no option is needed.
  local spec = string.format("file:%s.otf",
                             PAGELLA_FILE[style] or PAGELLA_FILE.regular)
  local ok, f = pcall(fonts.definers.read, spec,
                      math.floor(size * RATIO + 0.5))
  if not ok or type(f) ~= "table" then return nil end
  local ok2, fid = pcall(font.define, f)
  if not ok2 or not fid then return nil end
  pagella_cache[key] = fid
  return fid
end

-- ------------------------------------------------- (1) digit run reversal

-- reverse the node order of the segment first..last (inclusive) inside the
-- list anchored at head; returns new head and the node AFTER the segment
-- (in the original order) so the scan can resume at n.next
local function reverse_segment(head, first, last)
  local nodes = {}
  local n = first
  while true do
    nodes[#nodes + 1] = n
    if n == last then break end
    if not n.next then break end
    n = n.next
  end
  local prev = first.prev
  local after = last.next
  local cur = prev
  for i = #nodes, 1, -1 do
    local node = nodes[i]
    node.prev = cur
    if cur then cur.next = node else head = node end
    cur = node
  end
  cur.next = after
  if after then after.prev = cur end
  return head, after
end

local function is_run_glyph(code)
  return DIGIT[code] or SEPARATOR[code]
end

local function fix_digits_list(head, trt_base)
  if not head then return head end
  local n = head
  -- base direction: the line hlist's own dir field; dir nodes push/pop
  -- around it (luabidi emits signed "+TRT"/"-TRT"/"+TLT"/"-TLT" forms)
  local trt = trt_base or false
  while n do
    local nxt = n.next
    if n.id == node.id("dir") then
      local d = tostring(n.dir)
      if d == "+TRT" or d == "TRT" then
        trt = true
      else
        trt = trt_base or false
      end
    elseif n.id == node.id("glyph") and trt then
      local code = node_code(n)
      if code and DIGIT[code] then
        -- collect the maximal run: digits, separators, transparent discs
        local last = n
        local count_digits = 1
        local m = n.next
        while m do
          local mcode
          if m.id == node.id("glyph") then
            mcode = node_code(m)
          elseif m.id == node.id("disc") then
            m = m.next  -- untaken discretionary hyphen: transparent
            goto continue
          elseif m.id == node.id("kern") then
            m = m.next
            goto continue
          else
            break
          end
          if mcode and is_run_glyph(mcode) then
            if DIGIT[mcode] then count_digits = count_digits + 1 end
            last = m
            m = m.next
          else
            break
          end
          ::continue::
        end
        -- trim trailing separators (they must sit BETWEEN digits)
        while last ~= n do
          local lcode = node_code(last)
          if lcode and SEPARATOR[lcode] and not DIGIT[lcode] then
            last = last.prev
            -- skip back over transparent kerns/discs
            while last and (last.id == node.id("kern") or last.id == node.id("disc")) do
              last = last.prev
            end
            if not last then break end
          else
            break
          end
        end
        if count_digits >= 1 and last and last ~= n.prev then
          -- a single trailing % or ° joins the run
          local after = last.next
          while after and (after.id == node.id("kern") or after.id == node.id("disc")) do
            after = after.next
          end
          if after and after.id == node.id("glyph") then
            local acode = node_code(after)
            if acode and TRAILING[acode] then
              last = after
              after = after.next
            end
          end
          head, nxt = reverse_segment(head, n, last)
        end
      end
    end
    n = nxt
  end
  return head
end

-- recurse into the shipout list: lines are hlists inside the page vlist,
-- and dir nodes + glyph runs live inside those line lists
local function fix_digits(head)
  if not head then return head end
  local n = head
  while n do
    if n.id == node.id("hlist") then
      n.head = fix_digits_list(n.head, tostring(n.dir) == "TRT")
      n.head = fix_digits(n.head)
    elseif n.id == node.id("vlist") then
      n.head = fix_digits(n.head)
    end
    n = n.next
  end
  return head
end

-- ---------------------------------------------------- (2) fontsplit remap

-- R2 amendment (2026-11-15, owner-authorized): is_arabic_font matches
-- Amiri only, never Noto Naskh Arabic. That single correction reproduces
-- the accepted edition's measured behavior: Noto chapter-heading and TOC
-- digits were never remapped in it because Noto was never a remap source,
-- while every Amiri digit the filter reaches was remapped regardless of
-- nesting — prose digits sit two to three hlist levels inside the line
-- (node-tree probes, /tmp/tree-dump2.txt), so a recursion depth cutoff
-- would leave them in Amiri and break the census. Unconditional recursion
-- into hlists AND vlists is therefore kept exactly as it was.

local function remap_glyphs(head)
  if not head then return head end
  local n = head
  while n do
    if n.id == node.id("hlist") or n.id == node.id("vlist") then
      remap_glyphs(n.head)
    elseif n.id == node.id("glyph") then
      if is_arabic_font(n.font) then
        local code = node_code(n)
        if code and REMAP[code] then
          local f = font.getfont(n.font)
          local fid = pagella_fid(f.size, font_style(f))
          if fid then n.font = fid end
        end
      end
    end
    n = n.next
  end
  return head
end

-- ---------------------------------------------------------- registration

local function post_linebreak_filter(head)
  head = remap_glyphs(head)
  head = fix_digits(head)
  return head
end

if luatexbase and luatexbase.add_to_callback then
  luatexbase.add_to_callback("post_linebreak_filter", post_linebreak_filter,
                             "arabic-digits.post_linebreak_filter")
else
  callbacks.register("post_linebreak_filter", post_linebreak_filter,
                     "arabic-digits.post_linebreak_filter")
end

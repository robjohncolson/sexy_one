{-# LANGUAGE OverloadedStrings #-}

-- | Pure @'Block'\/'Inline' -> 'View'@ rendering, per the M1 DOM contract
-- (briefs\/M1-manifest.json, "Block-level classes produced by the
-- renderer"). No routing decisions live here beyond building an
-- @a.page-ref@ href from a page number, and no manual text is ever typed
-- literally -- every string rendered comes from the parsed corpus.
--
-- 'Data.Text.Text' is converted to 'MisoString' only at this render
-- boundary (via 'ms'); everything upstream (the parser, the outline, the
-- stats) works in plain 'Data.Text.Text'.
module View.Blocks
  ( renderBlocks
  , renderBlock
  , renderInlines
  , renderInline
  ) where

import qualified Data.Text          as T

import           Miso
import           Miso.Html.Element  as H
import           Miso.Html.Property as P

import           SXC1.Content.Types
import           SXC1.Route         (Route (RPage), renderRoute)

-- | Render a page's (or a quote's, or a list item's) blocks in order.
renderBlocks :: T.Text -> [Block] -> [View model action]
renderBlocks slug = map (renderBlock slug)

renderBlock :: T.Text -> Block -> View model action
renderBlock slug blk = case blk of
  -- A nested heading (inside a blockquote or list item, e.g. the guide
  -- book's "Tip" callouts) is not an outline target and was never given a
  -- slug from the page's anchor supply (see 'SXC1.Content.Markdown.mkDoc'
  -- / 'SXC1.Content.Markdown.parseBlocksEngine'), so its anchor is the
  -- empty string; render it as a real heading element with no id, rather
  -- than inventing or borrowing an anchor.
  Heading lvl inlines anchor ->
    headingTag (clampLevel lvl) (idAttrs anchor) (renderInlines slug inlines)

  Para inlines -> H.p_ [] (renderInlines slug inlines)

  Figure kind capInlines ->
    H.figure_ [ P.class_ "md-figure" ]
      [ H.figcaption_ [] (figcaptionInlines slug kind capInlines) ]

  Bullets items -> H.ul_ [] (map (renderListItem slug) items)

  Numbered start items -> H.ol_ [ intProp "start" start ] (map (renderListItem slug) items)

  Quote inner -> H.blockquote_ [ P.class_ "md-note" ] (renderBlocks slug inner)

  Table mHeader rows ->
    H.div_ [ P.class_ "table-wrap" ]
      [ H.table_ [] ( theadOf mHeader ++ [ H.tbody_ [] (map (renderRow H.td_) rows) ] ) ]

  -- MUST never occur in the real corpus (exe:content-check asserts zero
  -- 'Unparsed' blocks corpus-wide) -- rendered with a visible marker class
  -- rather than silently swallowed, so a grammar regression fails loudly
  -- in the browser too, not just in the checker.
  Unparsed t -> H.p_ [ P.class_ "md-unparsed" ] [ text (ms t) ]
  where
    theadOf Nothing    = []
    theadOf (Just hdr) = [ H.thead_ [] [ renderRow H.th_ hdr ] ]

    renderRow cellTag cells = H.tr_ [] [ cellTag [] (renderInlines slug cell) | cell <- cells ]

renderListItem :: T.Text -> ListItem -> View model action
renderListItem slug (ListItem content children) =
  H.li_ [] (renderInlines slug content ++ renderBlocks slug children)

renderInlines :: T.Text -> [Inline] -> [View model action]
renderInlines slug = map (renderInline slug)

renderInline :: T.Text -> Inline -> View model action
renderInline slug inl = case inl of
  Str t              -> text (ms t)
  Strong xs          -> H.strong_ [] (renderInlines slug xs)
  Em xs              -> H.em_ [] (renderInlines slug xs)
  Code t             -> H.code_ [] [ text (ms t) ]
  Break              -> H.br_ []
  Placeholder _ full -> H.span_ [ P.class_ "md-placeholder" ] [ text (ms (placeholderText full)) ]
  PageRef n disp     ->
    H.a_ [ P.class_ "page-ref", P.href_ (ms (renderRoute (RPage slug n False))) ] [ text (ms disp) ]

-- | Strip the @*[@ \/ @]*@ markers off a placeholder's full source text
-- (e.g. @\"*[QR code]*\"@ -> @\"QR code\"@) for inline display.
placeholderText :: T.Text -> T.Text
placeholderText full = maybe full id (T.stripSuffix "]*" =<< T.stripPrefix "*[" full)

-- | A figure's caption: \"kind: caption\" when there is caption text,
-- otherwise just the kind (e.g. an inline @*[pad icon]*@ promoted to a
-- block has no caption, only a kind).
figcaptionInlines :: T.Text -> T.Text -> [Inline] -> [View model action]
figcaptionInlines slug kind capInlines
  | null capInlines = [ text (ms kind) ]
  | otherwise        = text (ms (kind <> ": ")) : renderInlines slug capInlines

clampLevel :: Int -> Int
clampLevel n = max 1 (min 4 n)

idAttrs :: T.Text -> [Attribute action]
idAttrs anchor
  | T.null anchor = []
  | otherwise     = [ P.id_ (ms ("h-" <> anchor)) ]

headingTag :: Int -> [Attribute action] -> [View model action] -> View model action
headingTag 1 = H.h1_
headingTag 2 = H.h2_
headingTag 3 = H.h3_
headingTag _ = H.h4_

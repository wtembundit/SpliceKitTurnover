# Conform Prep Title And Marker Preservation Notes

This note records the practical rules learned while fixing real-world `Conform Prep` title and marker loss. The same rules should be reused when improving other Turnover scripts that move, rebuild, flatten, or generate FCPXML titles and markers.

## Verification Snapshot

Test timeline:

- `PROJECT_A_LONGFORM`
- Original Timeline Index title count: `299`
- Imported Conform Prep title count after the fix: `299`
- XML title identity diff: `0 missing`, `0 added`
- Empty default source markers after the fix: `0`
- DTD validation: passed
- Latest import/export XML after the title-anchor follow-up still contains all `299` titles.
- Latest import/export XML has `161` meaningful markers and `0` empty default `Marker N` markers.

Timeline Index CSV can still report apparent moved titles when matching by `Name + Notes` only. This is expected for repeated companion titles with empty notes, such as `CG description - Basic Title`, because several distinct title instances share the same visible name and note text. XML identity matching is more reliable for proving that titles are present; visual QA is still required for placement and stacking.

Follow-up fix: four titles around two adjacent anonymized shots initially survived import but reported different Timeline Index positions and visually overlapped. The fix was to preserve each title's own connection point instead of forcing every nested-retime title to the same parent start:

- titles whose connection point starts inside the flattened clip stay attached to that clip, even when their duration continues across later primary-storyline clips
- titles that start before the available anchor remain spine siblings in timeline time
- top-level sibling titles should be checked again after flattening; if their connection point belongs to a nearby previous clip, relocate them into that clip so FCP does not silently drop them on import

## Title Rules That Worked

### 1. Do Not Normalize Every Nested Title To Parent Start

Forcing every nested title `offset` to the parent clip `start` causes titles that span multiple clips to collapse at the same connection point. This creates overlap and makes titles look missing even when the XML still contains them.

Correct behavior:

- Preserve the original title timing whenever it is valid.
- Snap title offsets to the edit frame boundary only when needed.
- Do not clamp title offsets to the parent clip start unless the title is intentionally clip-local.

### 2. Sync-Clip Titles Start In Sync Source Time

Titles carried by a `sync-clip` usually use the sync clip's `start` time domain, not the parent timeline `offset` domain. If such a title is hoisted out as a top-level spine sibling without rebasing, Final Cut Pro can drop it during import.

Correct behavior when hoisting:

```text
new title offset = sync.offset + (title.offset - sync.start)
```

This keeps the title at the same timeline position while moving it out of the sync source-time domain.

### 3. Connected Titles Should Stay With Their Valid Anchor

Some titles are connected to a sync clip and begin inside that clip, but their duration intentionally continues across later clips. The title's connection point determines ownership; its end does not need to fit inside the anchor clip.

If these titles are emitted as top-level spine siblings, Final Cut Pro can drop them during import. The robust rule is:

- If the title connection point is inside the flattened clip timeline window, keep it inside the flattened clip.
- Rebase the title from `sync.start` to the flattened clip's source/start domain.
- Preserve the full title duration so titles can span later clips.
- If the title starts before the available clip anchor, keep it as a spine sibling and rebase it to timeline time.
- If a title becomes a top-level sibling but its connection point belongs to a nearby previous clip, relocate it into that clip as a final cleanup pass.

This split avoids both classes of bugs:

- clip-local titles disappearing on import
- long titles collapsing or being clipped inside one parent clip

### 4. Preserve Lanes, Notes, Enabled State, Duration, And Text Styles

When copying titles, preserve:

- `lane`
- `role`
- `enabled`
- `duration`
- `<note>`
- `<text>` and `<text-style-def>`
- visual params such as position, flatten, alignment, blend, and transforms

Also keep text-style IDs globally unique. Duplicate `text-style-def` IDs can produce DTD or import problems.

### 5. Timeline Index Count Is Necessary But Not Sufficient

Title count and identity diff are useful first checks, but they do not prove visual correctness.

Always also inspect:

- titles that moved in Timeline Index
- titles spanning more than one clip
- titles attached to nested-retime clips
- disabled titles
- paired VFX titles, such as a shot-code title plus a companion CG-description title

Nested-retime cases can preserve title identity while still be visually wrong if every title is forced to the same parent start. Preserve each title's own connection point and duration independently.

## Marker Cleanup Rule

Flattening can reveal generic source markers from inside camera/source clips. These often appear as:

```text
value="Marker 1"
value="Marker 2"
note=""
```

These are not editorial/VFX markers and can look like marker over-generation after conform prep.

Correct behavior:

- Remove only unnamed default source markers matching `Marker N` with no note.
- Preserve markers with shot codes.
- Preserve markers with notes, CG descriptions, ADR notes, or any user-authored metadata.
- Preserve chapter markers and other meaningful marker types unless there is a specific rule to remove them.

This marker rule should be reused when fixing Auto Marker or any script that derives markers from existing timeline/source metadata.

## Generic QA Checklist For Other Scripts

When a script edits title or marker FCPXML, check:

- Does the item live in timeline time, sync source time, or source clip time?
- If the item is hoisted to the spine, was its `offset` rebased to timeline time?
- If the item is kept inside a clip, was its `offset` rebased to that clip's source/start time?
- Does a title fit fully inside its parent clip window, or does it span across clips?
- Are title offsets on the edit frame boundary?
- Are all title IDs, style IDs, lanes, notes, roles, and enabled states preserved?
- Are default unnamed source markers filtered without deleting meaningful markers?
- Does the generated XML pass DTD validation?
- After Final Cut Pro imports and re-exports the XML, do title/marker counts and identities still match?

## Can Titles Be Placed Only By Original Timeline Time?

Partially, but not as a complete generic rule.

The idea is useful as an intermediate model: compute the title's intended absolute timeline window first, independent of which clip currently owns it. This helps prevent drift and makes it easier to compare before/after timelines.

However, Final Cut Pro FCPXML still needs every title to be structurally anchored somewhere:

- as a top-level spine sibling in timeline time
- or nested inside a clip/asset-clip in that clip's source/start time

The same absolute title can be valid in one structure and silently dropped in another. In the anonymized long-form fixture, some titles existed in the patched XML as top-level spine siblings at the correct absolute timeline time, but FCP dropped them on import. Restoring each title to the clip containing its connection point made FCP keep them without shortening titles that span later clips.

Best generic model:

1. Compute each title's intended absolute timeline start/end.
2. Decide the safest FCPXML anchor.
3. If the title's connection point belongs to a flattened clip, nest it in that clip and convert the absolute connection time to clip source/start time; preserve the full duration even when it spans later clips.
4. If no valid clip owns the connection point, keep it as a spine sibling and write the absolute timeline offset.
5. After import/export, verify identity count and visually inspect titles with duplicate names, empty notes, retime, or cross-clip spans.

## Known Concerns

- Complex nested retime and speed-ramp clips can still need visual QA because title timing may need to cross between source-time and timeline-time domains.
- FCP may silently drop top-level titles that look valid in XML but are connected to a clip-local sync title shape.
- Titles spanning several clips should not be forced inside one parent clip.
- A title count of `299/299` does not guarantee the visual stacking/order is perfect.
- Timeline Index CSV matching by `Name + Notes` is ambiguous for repeated generic companion titles; XML identity and visual inspection are more reliable.
- Marker cleanup should stay conservative; deleting all `Marker 1` blindly would be unsafe if a user intentionally named a marker that way and added a note.

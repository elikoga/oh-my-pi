Generates or edits images using Gemini image models.

<instructions>
- You **MUST** provide a single detailed `subject` prompt for image generation or editing.
- When using multiple `input`, you **SHOULD** describe each image's role directly in `subject`, e.g. `Image 1` for composition reference, `Image 2` for lighting reference, `Image 3` for background.
- For reference-guided generation, set `reference_type` on each `input` entry to clarify how the model should use it:
  - `"style"` — borrow the visual aesthetic (color palette, brushwork, art movement)
  - `"subject"` — preserve a specific object, product, or scene element
  - `"person"` — maintain a human's identity and appearance across generations
- For text: you **SHOULD** add "sharp, legible, correctly spelled" for important text; keep text short
</instructions>
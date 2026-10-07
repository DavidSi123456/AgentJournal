# README walkthroughs

These three English GIFs show the actual native macOS application in its isolated
demo mode, not an illustration of a proposed interface.

| Asset | Demonstrated workflow |
| --- | --- |
| `agentjournal-daily-en.gif` | Calendar selection, source filtering, editing and confirming a daily note |
| `agentjournal-thread-en.gif` | Cross-day thread browsing, confirmed task progress, saving and revisiting daily versions |
| `agentjournal-share-en.gif` | Choosing included threads and titles, previewing pages, successful PNG export |

All conversations, titles and notes in these recordings are synthetic. Demo edits
remain in memory. Model calls are disabled: the recordings demonstrate reviewing
existing demo drafts, not successful live model generation. No real transcript,
account, private backup or file-selection dialog is included.

The GIFs are macOS demonstrations, not Windows compatibility tests. They loop at
1200 × 900 pixels and total approximately 1.4 MiB.

## Reproduce on macOS

1. From the repository root, run `zsh scripts/preview_readme_demo.sh` and open the
   demo-only app bundle whose path it prints. It has a separate bundle identifier,
   forces the English synthetic demo through its Info.plist, and does not replace
   the installed AgentJournal app.
2. Capture the demonstrated UI states using window-only screenshots. Use only the
   isolated demo, never a normal session containing real chats. Place the captures
   under `.build/readme-gif/`: `daily/01.png` through `06.png`, `thread/01.png`
   through `06.png`, and `share/01.png` through `05.png`. The renderer detects the
   image format from its contents.
3. Run `zsh scripts/build_readme_gifs.sh` with Swift and FFmpeg installed. The Swift
   renderer adds the English captions; FFmpeg encodes the three looping GIFs into
   `docs/media/`.
4. Inspect every rendered frame and decode each resulting GIF before publishing.

Raw screenshots, rendered intermediate frames and the test PNG export stay under
the ignored `.build/` directory. Only these public, synthetic GIFs belong in Git.

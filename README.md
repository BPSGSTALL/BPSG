# Skill Arcade — School Game Stall

A browser-based arcade using your Supabase project. Includes player sign-in, persistent credit balances, a protected admin panel, digital games, VR/PlayStation staff-counter records, and transaction history. **The AI Photo Booth has been removed.**

## Included games

- Quiz Master — multiple-choice quiz
- Kaun Banega 100 Pati — 10-level progressive quiz with a 50–50 lifeline. Correct-level rewards remain pending until the player chooses Quit & Collect; completing all 10 levels collects the full total automatically. A wrong answer discards all pending rewards from that run. Default level rewards: 4, 6, 8, 10, 12, 15, 20, 25, 35, 50 credits.
- Guess the Number — hints and limited attempts
- Maze Runner — generated maze
- Sliding Puzzle — 8-puzzle
- Math Sprint — timed arithmetic
- Memory Match — pair matching
- Tic-Tac-Toe — player versus computer
- VR Experience — staff-operated physical station
- PlayStation Challenge — staff-operated physical station

Memory Match and Tic-Tac-Toe are currently casual games with no completion bonus. Their entry fees are configurable in Admin. VR and PlayStation do not control hardware; authorized staff record charges and wins.

## Supabase configuration

`config.js` contains the project URL and publishable/anon key from your supplied file. A publishable/anon key is designed for browser use; never put a service-role key or other privileged secret in frontend code. If you have already shared a real privileged key publicly, rotate it.

## Setup

1. Back up your Supabase project first.
2. Open `supabase-schema.sql` and replace `CHANGE_THIS_ADMIN_PASSWORD_BEFORE_RUNNING` with a strong initial admin password. Do not use a password you use elsewhere.
3. Run the full SQL file in Supabase Dashboard → SQL Editor. It creates tables, functions, default games and sample questions. Review the SQL output for errors before continuing.
4. Check `config.js` has the correct Supabase project URL and publishable/anon key. The values were copied from the uploaded file; replace them if you have rotated the key or changed projects.
5. From this folder run `python -m http.server 8080`, then open `http://localhost:8080`. Do not open pages with `file://`.
6. Open `admin.html`, log in with the initial admin password, create a test player, then test player login at `index.html`. Change the admin password in the dashboard.

## Admin features

- Create accounts without student email (username and 4–6 digit PIN).
- Search players, suspend/reactivate accounts, reset PINs.
- Add credits or make a reasoned adjustment.
- Record VR/PlayStation charges and station rewards.
- Change game fees, win amounts and availability. KBC level rewards are defined in `supabase-schema.sql` in the KBC `start_game` setup; change the reward array there if desired, then apply the updated SQL to Supabase.
- Add questions for Quiz Master and KBC.
- Review player balances and transaction history.

## Security notes

- Never share the Supabase service-role key. Only the publishable/anon key belongs in `config.js`.
- This legacy RPC architecture sends the player's PIN with each RPC request and keeps it in `sessionStorage` for the current browser tab. For a public production system, migrate to Supabase Auth or a dedicated server-side session architecture. Use under school supervision.
- Take a database backup before rerunning schema changes against an existing project. The schema is intended to be repeatable, but always inspect errors and test on a development project first.
- The simple Memory Match and Tic-Tac-Toe completion endpoint deliberately awards no credits because client-side game results are not strong enough evidence for secure rewards.

## Test checklist

1. Run SQL and confirm it completes without errors.
2. Admin login → create a test player with 50 credits.
3. Log in as the player and refresh; confirm the balance persists.
4. Start each digital game; confirm the fee is deducted and a ledger entry appears.
5. Test insufficient balance rejection.
6. Test memory pairs and Tic-Tac-Toe gameplay.
7. Add/deduct credits with a reason and confirm the history.
8. Change a game price and confirm the catalogue reflects it.
9. Test station charges and wins with a test player.
10. Verify a player cannot open admin operations without the admin password.
11. KBC test: answer level 1 correctly (4 pending), choose Play Next, answer level 2 correctly (10 pending total), then choose Quit & Collect; the balance should increase by 10. Start another run, answer levels 1–3 correctly, continue to level 4, then answer incorrectly; the run should award 0 and discard all pending rewards from that run.

## Files

- `index.html`, `games.html`, `admin.html`, `history.html`
- `style.css`, `config.js`, `common.js`, `app.js`, `games.js`, `admin.js`, `history.js`
- `supabase-schema.sql`, `supabase/config.toml`

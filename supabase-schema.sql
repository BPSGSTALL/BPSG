-- =====================================================================
--  SKILL ARCADE - credits system for the school stall
--  1) Change the admin password on the line marked  <<< CHANGE ME
--  2) Paste this whole file in  Supabase > SQL Editor > Run
--  Safe to run again later (it never deletes players, credits or history).
--
--  How it stays safe: the tables are locked (nobody can read or edit them
--  directly from the browser). Everything goes through the functions below,
--  which check the player's PIN / the admin password on the server.
-- =====================================================================
create extension if not exists pgcrypto with schema extensions;

-- ------------------------------------------------------------ TABLES
create table if not exists settings (
  key text primary key,
  value text not null
);

create table if not exists players (
  id bigserial primary key,
  username text not null,
  pin_hash text not null,
  credits int not null default 0 check (credits >= 0),
  created_at timestamptz not null default now()
);
create unique index if not exists players_username_key on players (lower(username));
alter table players add column if not exists status text not null default 'active' check (status in ('active','suspended'));

create table if not exists games (
  id text primary key,
  name text not null,
  kind text not null check (kind in ('digital', 'station')),
  description text,
  price int not null default 10 check (price >= 0),        -- credits to play
  win_amount int not null default 20 check (win_amount >= 0), -- credits for winning
  enabled boolean not null default true,
  sort int not null default 100
);

create table if not exists transactions (
  id bigserial primary key,
  player_id bigint not null references players (id),
  username text not null,
  type text not null check (type in ('topup', 'game_fee', 'win', 'adjust')),
  amount int not null,                 -- + credits in, - credits out
  balance_after int not null,
  game_id text,
  note text,
  created_at timestamptz not null default now()
);
create index if not exists transactions_player_idx on transactions (player_id, id desc);

create table if not exists questions (
  id bigserial primary key,
  mode text not null check (mode in ('quiz', 'kbc')),
  level int not null default 1,        -- KBC level 1..10 (quiz ignores it)
  question text not null,
  options jsonb not null,
  answer int not null check (answer between 0 and 3)
);

create table if not exists game_sessions (
  id bigserial primary key,
  player_id bigint not null references players (id),
  game_id text not null references games (id),
  state jsonb not null default '{}'::jsonb,
  status text not null default 'active' check (status in ('active', 'won', 'lost')),
  fee int not null,
  win int not null default 0,
  result jsonb,
  started_at timestamptz not null default clock_timestamp(),
  ended_at timestamptz
);

-- ------------------------------------------------------------ INTERNAL HELPERS
create or replace function _auth_player(p_user text, p_pin text)
returns players language plpgsql security definer set search_path = public, extensions as $$
declare r players;
begin
  select * into r from players where lower(username) = lower(trim(coalesce(p_user, ''))) for update;
  if not found or r.pin_hash is distinct from crypt(coalesce(p_pin, ''), r.pin_hash) then
    raise exception 'Wrong username or PIN';
  end if;
  if r.status <> 'active' then raise exception 'This account is suspended. Please contact the stall administrator.'; end if;
  return r;
end $$;

create or replace function _check_admin(p_admin text)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare h text;
begin
  select value into h from settings where key = 'admin_hash';
  if h is null or h is distinct from crypt(coalesce(p_admin, ''), h) then
    raise exception 'Wrong admin password';
  end if;
end $$;

-- the ONLY place where credits change; also writes the history row
create or replace function _apply(p_pid bigint, p_amount int, p_type text, p_game text, p_note text)
returns int language plpgsql security definer set search_path = public, extensions as $$
declare bal int; uname text;
begin
  update players set credits = credits + p_amount where id = p_pid returning credits, username into bal, uname;
  insert into transactions (player_id, username, type, amount, balance_after, game_id, note)
  values (p_pid, uname, p_type, p_amount, bal, p_game, p_note);
  return bal;
end $$;

create or replace function _finish(p_sid bigint, p_won boolean, p_win int, p_msg text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare s game_sessions; bal int; res jsonb;
begin
  select * into s from game_sessions where id = p_sid for update;
  if s.status <> 'active' then return s.result; end if;
  if p_win > 0 then
    bal := _apply(s.player_id, p_win, 'win', s.game_id, p_msg);
  else
    select credits into bal from players where id = s.player_id;
  end if;
  res := jsonb_build_object('done', true, 'won', p_won, 'win', p_win, 'msg', p_msg, 'balance', bal);
  update game_sessions
     set status = case when p_won then 'won' else 'lost' end, win = p_win, result = res, ended_at = now()
   where id = p_sid;
  return res;
end $$;

create or replace function _get_session(p_pid bigint, p_sid bigint, p_games text[])
returns game_sessions language plpgsql security definer set search_path = public, extensions as $$
declare s game_sessions;
begin
  select * into s from game_sessions where id = p_sid and player_id = p_pid for update;
  if not found or not (s.game_id = any (p_games)) then raise exception 'Game session not found'; end if;
  return s;
end $$;

create or replace function _add_question(p_mode text, p_level int, p_q text, p_c text, p_w1 text, p_w2 text, p_w3 text)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare opts jsonb; idx int;
begin
  select jsonb_agg(o order by random()) into opts from unnest(array[p_c, p_w1, p_w2, p_w3]) o;
  select (ord - 1)::int into idx from jsonb_array_elements_text(opts) with ordinality t (v, ord) where v = p_c limit 1;
  insert into questions (mode, level, question, options, answer) values (p_mode, p_level, p_q, opts, idx);
end $$;

-- maze: cells numbered row*n+col, wall bits 1=up 2=right 4=down 8=left
create or replace function _gen_maze(n int)
returns int[] language plpgsql as $$
declare
  w int[] := array_fill(15, array[n * n]);
  vis boolean[] := array_fill(false, array[n * n]);
  stack int[] := array[0];
  cur int; nb int[]; nxt int; r int; c int;
begin
  vis[1] := true;
  while array_length(stack, 1) > 0 loop
    cur := stack[array_length(stack, 1)];
    r := cur / n; c := cur % n; nb := '{}';
    if r > 0     and not vis[cur - n + 1] then nb := nb || (cur - n); end if;
    if c < n - 1 and not vis[cur + 2]     then nb := nb || (cur + 1); end if;
    if r < n - 1 and not vis[cur + n + 1] then nb := nb || (cur + n); end if;
    if c > 0     and not vis[cur]         then nb := nb || (cur - 1); end if;
    if coalesce(array_length(nb, 1), 0) = 0 then
      stack := stack[1:array_length(stack, 1) - 1];
    else
      nxt := nb[1 + floor(random() * array_length(nb, 1))::int];
      if nxt = cur - n then
        w[cur + 1] := w[cur + 1] & ~1; w[nxt + 1] := w[nxt + 1] & ~4;
      elsif nxt = cur + 1 then
        w[cur + 1] := w[cur + 1] & ~2; w[nxt + 1] := w[nxt + 1] & ~8;
      elsif nxt = cur + n then
        w[cur + 1] := w[cur + 1] & ~4; w[nxt + 1] := w[nxt + 1] & ~1;
      else
        w[cur + 1] := w[cur + 1] & ~8; w[nxt + 1] := w[nxt + 1] & ~2;
      end if;
      vis[nxt + 1] := true;
      stack := stack || nxt;
    end if;
  end loop;
  return w;
end $$;

create or replace function _maze_ok(w int[], n int, moves text)
returns boolean language plpgsql as $$
declare cur int := 0; ch text; i int;
begin
  for i in 1..coalesce(length(moves), 0) loop
    ch := substr(moves, i, 1);
    if ch = 'U' then
      if cur / n = 0 or (w[cur + 1] & 1) <> 0 then return false; end if;
      cur := cur - n;
    elsif ch = 'R' then
      if cur % n = n - 1 or (w[cur + 1] & 2) <> 0 then return false; end if;
      cur := cur + 1;
    elsif ch = 'D' then
      if cur / n = n - 1 or (w[cur + 1] & 4) <> 0 then return false; end if;
      cur := cur + n;
    elsif ch = 'L' then
      if cur % n = 0 or (w[cur + 1] & 8) <> 0 then return false; end if;
      cur := cur - 1;
    else
      return false;
    end if;
  end loop;
  return cur = n * n - 1;
end $$;

-- 8-puzzle: scramble by random legal moves (always solvable)
create or replace function _gen_puzzle()
returns int[] language plpgsql as $$
declare b int[] := array[1,2,3,4,5,6,7,8,0]; blank int := 8; last int := -1; i int; nb int[]; pick int;
begin
  for i in 1..60 loop
    nb := '{}';
    if blank / 3 > 0 and blank - 3 <> last then nb := nb || (blank - 3); end if;
    if blank / 3 < 2 and blank + 3 <> last then nb := nb || (blank + 3); end if;
    if blank % 3 > 0 and blank - 1 <> last then nb := nb || (blank - 1); end if;
    if blank % 3 < 2 and blank + 1 <> last then nb := nb || (blank + 1); end if;
    pick := nb[1 + floor(random() * array_length(nb, 1))::int];
    b[blank + 1] := b[pick + 1]; b[pick + 1] := 0;
    last := blank; blank := pick;
  end loop;
  if b = array[1,2,3,4,5,6,7,8,0] then return _gen_puzzle(); end if;
  return b;
end $$;

create or replace function _puzzle_ok(b int[], moves text)
returns boolean language plpgsql as $$
declare i int; k int; bl int;
begin
  for i in 1..coalesce(length(moves), 0) loop
    if substr(moves, i, 1) !~ '^[0-8]$' then return false; end if;
    k := substr(moves, i, 1)::int;
    bl := array_position(b, 0) - 1;
    if abs(k / 3 - bl / 3) + abs(k % 3 - bl % 3) <> 1 then return false; end if;
    b[bl + 1] := b[k + 1]; b[k + 1] := 0;
  end loop;
  return b = array[1,2,3,4,5,6,7,8,0];
end $$;

-- ------------------------------------------------------------ PLAYER API
create or replace function list_games()
returns jsonb language sql security definer set search_path = public as $$
  select coalesce(jsonb_agg((to_jsonb(g) - 'sort') order by g.sort, g.name), '[]'::jsonb) from games g
$$;

create or replace function player_me(p_user text, p_pin text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare pl players;
begin
  pl := _auth_player(p_user, p_pin);
  return jsonb_build_object('username', pl.username, 'credits', pl.credits,
    'history', (select coalesce(jsonb_agg(to_jsonb(x) order by x.id desc), '[]'::jsonb)
                from (select id, created_at, type, amount, balance_after, game_id, note
                      from transactions where player_id = pl.id order by id desc limit 25) x));
end $$;

create or replace function start_game(p_user text, p_pin text, p_game text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  pl players; g games; st jsonb; sid bigint; bal int; qs jsonb := '[]'::jsonb; need int; lim int;
  i int; a int; b int; c int; t int; qtxt text; ans int; lad jsonb; walls int[]; brd int[]; first_q jsonb;
begin
  pl := _auth_player(p_user, p_pin);
  select * into g from games where id = p_game;
  if not found or g.kind <> 'digital' then raise exception 'Unknown game'; end if;
  if not g.enabled then raise exception 'This game is closed right now'; end if;
  if pl.credits < g.price then raise exception 'Not enough credits (this game costs % credits)', g.price; end if;

  update game_sessions
     set status = 'lost', ended_at = now(), result = jsonb_build_object('done', true, 'won', false, 'win', 0, 'msg', 'Game abandoned')
   where player_id = pl.id and status = 'active';

  st := jsonb_build_object('win_amount', g.win_amount);

  if p_game = 'quiz' then
    select coalesce(jsonb_agg(jsonb_build_object('q', question, 'o', options, 'a', answer)), '[]'::jsonb) into qs
      from (select * from questions where mode = 'quiz' order by random() limit 8) x;
    if jsonb_array_length(qs) = 0 then raise exception 'No quiz questions added yet'; end if;
    need := least(6, jsonb_array_length(qs)); lim := 0;
    st := st || jsonb_build_object('qs', qs, 'i', 0, 'correct', 0, 'need', need, 'limit', lim);

  elsif p_game = 'math' then
    for i in 1..8 loop
      t := floor(random() * 6)::int;
      if t = 0 then
        a := 23 + floor(random() * 76)::int; b := 23 + floor(random() * 76)::int;
        qtxt := a::text || ' + ' || b::text; ans := a + b;
      elsif t = 1 then
        a := 60 + floor(random() * 141)::int; b := 11 + floor(random() * (a - 15))::int;
        qtxt := a::text || ' - ' || b::text; ans := a - b;
      elsif t = 2 then
        a := 6 + floor(random() * 10)::int; b := 6 + floor(random() * 10)::int;
        qtxt := a::text || ' × ' || b::text; ans := a * b;
      elsif t = 3 then
        a := 12 + floor(random() * 14)::int; b := 3 + floor(random() * 7)::int;
        qtxt := a::text || ' × ' || b::text; ans := a * b;
      elsif t = 4 then
        a := 2 + floor(random() * 11)::int; b := 5 + floor(random() * 16)::int; c := 2 + floor(random() * 8)::int;
        qtxt := a::text || ' × ' || b::text || ' + ' || c::text; ans := a * b + c;
      else
        a := 30 + floor(random() * 61)::int; b := 10 + floor(random() * 31)::int; c := 2 + floor(random() * 8)::int;
        qtxt := a::text || ' - ' || b::text || ' + ' || c::text; ans := a - b + c;
      end if;
      qs := qs || jsonb_build_array(jsonb_build_object('q', qtxt || ' = ?', 'a', ans));
    end loop;
    need := 7; lim := 75;
    st := st || jsonb_build_object('qs', qs, 'i', 0, 'correct', 0, 'need', need, 'limit', lim);

  elsif p_game = 'guess' then
    lim := 90;
    st := st || jsonb_build_object('target', 1 + floor(random() * 100)::int, 'tries', 0, 'max_tries', 6, 'limit', lim);

  elsif p_game = 'maze' then
    walls := _gen_maze(10); lim := 75;
    st := st || jsonb_build_object('walls', to_jsonb(walls), 'n', 10, 'limit', lim, 'min', 4);

  elsif p_game = 'puzzle' then
    brd := _gen_puzzle(); lim := 120;
    st := st || jsonb_build_object('board', to_jsonb(brd), 'limit', lim, 'min', 6);

  elsif p_game = 'memory' then
    st := st || jsonb_build_object('mode','memory');
    lim := 0;

  elsif p_game = 'ttt' then
    st := st || jsonb_build_object('mode','ttt');
    lim := 0;

  elsif p_game = 'kbc' then
    select jsonb_agg(jsonb_build_object('q', question, 'o', options, 'a', answer, 'lvl', level) order by level) into qs
      from (select distinct on (level) * from questions where mode = 'kbc' and level between 1 and 10 order by level, random()) x;
    if qs is null or jsonb_array_length(qs) < 10 then raise exception 'KBC needs 1 question for each level 1-10'; end if;
    select to_jsonb(array[4,6,8,10,12,15,20,25,35,50]) into lad;
    st := st || jsonb_build_object('qs', qs, 'i', 0, 'ladder', lad, 'earned', 0, 'used50', false);
    lim := 0;
  else
    raise exception 'Game not ready';
  end if;

  bal := _apply(pl.id, -g.price, 'game_fee', g.id, g.name);
  insert into game_sessions (player_id, game_id, state, fee) values (pl.id, g.id, st, g.price) returning id into sid;

  if p_game in ('quiz', 'math') then
    first_q := jsonb_build_object('q', qs -> 0 ->> 'q', 'o', qs -> 0 -> 'o');
    return jsonb_build_object('session', sid, 'balance', bal, 'total', jsonb_array_length(qs),
                              'need', need, 'limit', lim, 'question', first_q);
  elsif p_game = 'guess' then
    return jsonb_build_object('session', sid, 'balance', bal, 'tries', 6, 'limit', lim);
  elsif p_game in ('memory','ttt') then
    return jsonb_build_object('session', sid, 'balance', bal, 'limit', 0);
  elsif p_game = 'maze' then
    return jsonb_build_object('session', sid, 'balance', bal, 'n', 10, 'walls', to_jsonb(walls), 'limit', lim);
  elsif p_game = 'puzzle' then
    return jsonb_build_object('session', sid, 'balance', bal, 'board', to_jsonb(brd), 'limit', lim);
  else
    return jsonb_build_object('session', sid, 'balance', bal, 'ladder', lad, 'safe', jsonb_build_array(4, 7),
                              'question', jsonb_build_object('lvl', 1, 'q', qs -> 0 ->> 'q', 'o', qs -> 0 -> 'o'));
  end if;
end $$;

create or replace function _quiz_end(p_sid bigint, p_st jsonb)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare c int := (p_st ->> 'correct')::int; need int := (p_st ->> 'need')::int; total int := jsonb_array_length(p_st -> 'qs');
begin
  return _finish(p_sid, c >= need, case when c >= need then (p_st ->> 'win_amount')::int else 0 end,
                 c::text || ' of ' || total::text || ' correct (needed ' || need::text || ')');
end $$;

create or replace function quiz_answer(p_user text, p_pin text, p_session bigint, p_answer int)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare pl players; s game_sessions; st jsonb; q jsonb; ok boolean; i int; total int; lim int; ca int;
begin
  pl := _auth_player(p_user, p_pin);
  s := _get_session(pl.id, p_session, array['quiz', 'math']);
  if s.status <> 'active' then return jsonb_build_object('done', true, 'result', s.result); end if;
  st := s.state; lim := coalesce((st ->> 'limit')::int, 0);
  if lim > 0 and extract(epoch from (clock_timestamp() - s.started_at)) > lim + 2 then
    return jsonb_build_object('done', true, 'result', _quiz_end(s.id, st));
  end if;
  i := (st ->> 'i')::int; q := st -> 'qs' -> i;
  ok := coalesce((q ->> 'a')::int = p_answer, false);
  if ok then st := jsonb_set(st, '{correct}', to_jsonb((st ->> 'correct')::int + 1)); end if;
  i := i + 1; st := jsonb_set(st, '{i}', to_jsonb(i));
  update game_sessions set state = st where id = s.id;
  total := jsonb_array_length(st -> 'qs');
  ca := case when (q -> 'o') is not null then (q ->> 'a')::int end;
  if i >= total then
    return jsonb_build_object('correct', ok, 'correct_answer', ca, 'done', true, 'result', _quiz_end(s.id, st));
  end if;
  return jsonb_build_object('correct', ok, 'correct_answer', ca, 'done', false,
    'question', jsonb_build_object('q', st -> 'qs' -> i ->> 'q', 'o', st -> 'qs' -> i -> 'o'));
end $$;

create or replace function quiz_finish(p_user text, p_pin text, p_session bigint)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare pl players; s game_sessions;
begin
  pl := _auth_player(p_user, p_pin);
  s := _get_session(pl.id, p_session, array['quiz', 'math']);
  if s.status <> 'active' then return s.result; end if;
  return _quiz_end(s.id, s.state);
end $$;

create or replace function guess_number(p_user text, p_pin text, p_session bigint, p_n int)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare pl players; s game_sessions; st jsonb; tgt int; tries int; hints jsonb; remaining int; lo int; res jsonb;
begin
  pl := _auth_player(p_user, p_pin);
  s := _get_session(pl.id, p_session, array['guess']);
  if s.status <> 'active' then return jsonb_build_object('done', true, 'result', s.result); end if;
  st := s.state; tgt := (st ->> 'target')::int;
  if extract(epoch from (clock_timestamp() - s.started_at)) > (st ->> 'limit')::int + 2 then
    return jsonb_build_object('done', true, 'result', _finish(s.id, false, 0, 'Time up! The number was ' || tgt::text));
  end if;
  if p_n is null or p_n < 1 or p_n > 100 then raise exception 'Enter a number from 1 to 100'; end if;
  tries := (st ->> 'tries')::int + 1;
  if p_n = tgt then
    hints := jsonb_build_array('Correct!');
  else
    hints := jsonb_build_array(
      case when p_n < tgt then 'Go HIGHER' else 'Go LOWER' end,
      case when abs(p_n - tgt) <= 5 then 'Very hot' when abs(p_n - tgt) <= 15 then 'Warm'
           when abs(p_n - tgt) <= 30 then 'Cool' else 'Cold' end);
    if tries = 2 then
      hints := hints || jsonb_build_array(case when tgt % 2 = 0 then 'It is EVEN' else 'It is ODD' end);
    elsif tries = 3 then
      hints := hints || jsonb_build_array('Divisible by 3: ' || case when tgt % 3 = 0 then 'YES' else 'NO' end);
    elsif tries = 5 then
      lo := greatest(1, least(81, tgt - floor(random() * 20)::int));
      hints := hints || jsonb_build_array('It is between ' || lo::text || ' and ' || (lo + 19)::text);
    end if;
  end if;
  st := jsonb_set(st, '{tries}', to_jsonb(tries));
  update game_sessions set state = st where id = s.id;
  remaining := (st ->> 'max_tries')::int - tries;
  if p_n = tgt then
    res := _finish(s.id, true, (st ->> 'win_amount')::int, 'Found it in ' || tries::text || ' tries!');
  elsif remaining <= 0 then
    res := _finish(s.id, false, 0, 'Out of tries. The number was ' || tgt::text);
  end if;
  return jsonb_build_object('hints', hints, 'used', tries, 'left', remaining, 'done', res is not null, 'result', res);
end $$;

create or replace function guess_finish(p_user text, p_pin text, p_session bigint)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare pl players; s game_sessions;
begin
  pl := _auth_player(p_user, p_pin);
  s := _get_session(pl.id, p_session, array['guess']);
  if s.status <> 'active' then return s.result; end if;
  return _finish(s.id, false, 0, 'Time up! The number was ' || (s.state ->> 'target'));
end $$;

create or replace function maze_finish(p_user text, p_pin text, p_session bigint, p_moves text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare pl players; s game_sessions; st jsonb; el numeric; walls int[]; n int;
begin
  pl := _auth_player(p_user, p_pin);
  s := _get_session(pl.id, p_session, array['maze']);
  if s.status <> 'active' then return s.result; end if;
  st := s.state; n := (st ->> 'n')::int;
  el := extract(epoch from (clock_timestamp() - s.started_at));
  walls := array(select jsonb_array_elements_text(st -> 'walls')::int);
  if el > (st ->> 'limit')::int + 3 then
    return _finish(s.id, false, 0, 'Time is up!');
  elsif length(coalesce(p_moves, '')) > 3000 or not _maze_ok(walls, n, p_moves) then
    return _finish(s.id, false, 0, 'You did not reach the exit.');
  elsif el < (st ->> 'min')::int then
    return _finish(s.id, false, 0, 'Too fast to be true - not counted.');
  end if;
  return _finish(s.id, true, (st ->> 'win_amount')::int, 'You escaped the maze in ' || round(el)::text || ' seconds!');
end $$;

create or replace function puzzle_finish(p_user text, p_pin text, p_session bigint, p_moves text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare pl players; s game_sessions; st jsonb; el numeric; brd int[];
begin
  pl := _auth_player(p_user, p_pin);
  s := _get_session(pl.id, p_session, array['puzzle']);
  if s.status <> 'active' then return s.result; end if;
  st := s.state;
  el := extract(epoch from (clock_timestamp() - s.started_at));
  brd := array(select jsonb_array_elements_text(st -> 'board')::int);
  if el > (st ->> 'limit')::int + 3 then
    return _finish(s.id, false, 0, 'Time is up!');
  elsif length(coalesce(p_moves, '')) > 600 or not _puzzle_ok(brd, p_moves) then
    return _finish(s.id, false, 0, 'The puzzle was not solved.');
  elsif el < (st ->> 'min')::int then
    return _finish(s.id, false, 0, 'Too fast to be true - not counted.');
  end if;
  return _finish(s.id, true, (st ->> 'win_amount')::int, 'Puzzle solved in ' || round(el)::text || ' seconds!');
end $$;

create or replace function kbc_answer(p_user text, p_pin text, p_session bigint, p_choice int)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare pl players; s game_sessions; st jsonb; i int; q jsonb; lad jsonb; ca int; prize int; earned int; bal int; res jsonb;
begin
  pl := _auth_player(p_user, p_pin);
  s := _get_session(pl.id, p_session, array['kbc']);
  if s.status <> 'active' then return jsonb_build_object('done', true, 'result', s.result); end if;
  st := s.state;
  if coalesce((st ->> 'awaiting_choice')::boolean, false) then
    raise exception 'Choose Play Next Level or Quit & Collect first';
  end if;
  i := (st ->> 'i')::int; q := st -> 'qs' -> i; lad := st -> 'ladder';
  earned := coalesce((st ->> 'earned')::int, 0);
  ca := (q ->> 'a')::int;
  if p_choice is not null and p_choice = ca then
    i := i + 1;
    prize := (lad ->> (i - 1))::int;
    earned := earned + prize;
    st := jsonb_set(jsonb_set(jsonb_set(st, '{i}', to_jsonb(i)), '{earned}', to_jsonb(earned)), '{last_prize}', to_jsonb(prize));
    if i >= 10 then
      update game_sessions set state = st where id = s.id;
      bal := _apply(pl.id, earned, 'win', s.game_id, 'KBC completed all 10 levels; collected total reward');
      res := _finish(s.id, true, 0, 'Amazing! All 10 levels completed. You collected ' || earned::text || ' credits.');
      res := res || jsonb_build_object('win', earned, 'balance', bal);
      update game_sessions set win = earned, result = res where id = s.id;
      return jsonb_build_object('correct', true, 'done', true, 'result', res, 'prize', prize, 'earned', earned, 'balance', bal);
    end if;
    st := jsonb_set(st, '{awaiting_choice}', 'true'::jsonb, true);
    update game_sessions set state = st where id = s.id;
    return jsonb_build_object('correct', true, 'done', false, 'levelComplete', true,
      'prize', prize, 'earned', earned, 'level', i);
  end if;

  res := _finish(s.id, false, 0, 'Wrong answer! Correct answer: ' || (q -> 'o' ->> ca) || '. You lost this run and its pending ' || earned::text || ' credits.');
  res := res || jsonb_build_object('win', 0);
  update game_sessions set win = 0, result = res where id = s.id;
  return jsonb_build_object('correct', false, 'done', true, 'correct_answer', ca, 'result', res);
end $$;

create or replace function kbc_continue(p_user text, p_pin text, p_session bigint)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare pl players; s game_sessions; st jsonb; i int;
begin
  pl := _auth_player(p_user, p_pin);
  s := _get_session(pl.id, p_session, array['kbc']);
  if s.status <> 'active' then return jsonb_build_object('done', true, 'result', s.result); end if;
  st := s.state;
  if not coalesce((st ->> 'awaiting_choice')::boolean, false) then
    raise exception 'Answer the current level first';
  end if;
  i := (st ->> 'i')::int;
  if i >= 10 then raise exception 'All levels are complete'; end if;
  st := jsonb_set(st, '{awaiting_choice}', 'false'::jsonb, true);
  update game_sessions set state = st where id = s.id;
  return jsonb_build_object('done', false, 'question', jsonb_build_object('lvl', i + 1, 'q', st -> 'qs' -> i ->> 'q', 'o', st -> 'qs' -> i -> 'o'));
end $$;

create or replace function kbc_quit(p_user text, p_pin text, p_session bigint)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare pl players; s game_sessions; earned int; bal int; res jsonb;
begin
  pl := _auth_player(p_user, p_pin);
  s := _get_session(pl.id, p_session, array['kbc']);
  if s.status <> 'active' then return s.result; end if;
  earned := coalesce((s.state ->> 'earned')::int, 0);
  if earned > 0 then
    bal := _apply(pl.id, earned, 'win', s.game_id, 'KBC quit and collected pending rewards');
  else
    select credits into bal from players where id = pl.id;
  end if;
  res := _finish(s.id, false, 0, 'You quit and collected ' || earned::text || ' credits from completed levels.');
  res := res || jsonb_build_object('win', earned, 'balance', bal);
  update game_sessions set win = earned, result = res where id = s.id;
  return res;
end $$;

create or replace function kbc_5050(p_user text, p_pin text, p_session bigint)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare pl players; s game_sessions; st jsonb; ca int; rem int[];
begin
  pl := _auth_player(p_user, p_pin);
  s := _get_session(pl.id, p_session, array['kbc']);
  if s.status <> 'active' then raise exception 'Game is over'; end if;
  st := s.state;
  if (st ->> 'used50')::boolean then raise exception 'You already used the 50-50 lifeline'; end if;
  ca := (st -> 'qs' -> (st ->> 'i')::int ->> 'a')::int;
  select array_agg(x) into rem from (select gs as x from generate_series(0, 3) gs where gs <> ca order by random() limit 2) t3;
  update game_sessions set state = jsonb_set(st, '{used50}', 'true'::jsonb) where id = s.id;
  return jsonb_build_object('remove', to_jsonb(rem));
end $$;

-- ------------------------------------------------------------ ADMIN API
create or replace function admin_check(p_admin text)
returns boolean language plpgsql security definer set search_path = public, extensions as $$
begin perform _check_admin(p_admin); return true; end $$;

create or replace function admin_change_password(p_admin text, p_new text)
returns boolean language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _check_admin(p_admin);
  if length(coalesce(p_new, '')) < 6 then raise exception 'New password must be at least 6 characters'; end if;
  update settings set value = crypt(p_new, gen_salt('bf')) where key = 'admin_hash';
  return true;
end $$;

create or replace function admin_create_player(p_admin text, p_username text, p_pin text, p_credits int)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare u text := trim(coalesce(p_username, '')); pid bigint; bal int := 0;
begin
  perform _check_admin(p_admin);
  if u !~ '^[A-Za-z0-9_]{3,20}$' then raise exception 'Username: 3-20 letters, numbers or underscore'; end if;
  if coalesce(p_pin, '') !~ '^[0-9]{4,6}$' then raise exception 'PIN must be 4 to 6 digits'; end if;
  if exists (select 1 from players where lower(username) = lower(u)) then raise exception 'Username already taken'; end if;
  insert into players (username, pin_hash) values (u, crypt(p_pin, gen_salt('bf'))) returning id into pid;
  if coalesce(p_credits, 0) > 0 then bal := _apply(pid, p_credits, 'topup', null, 'Starting credits'); end if;
  return jsonb_build_object('username', u, 'credits', bal);
end $$;

create or replace function admin_set_pin(p_admin text, p_user text, p_pin text)
returns boolean language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _check_admin(p_admin);
  if coalesce(p_pin, '') !~ '^[0-9]{4,6}$' then raise exception 'PIN must be 4 to 6 digits'; end if;
  update players set pin_hash = crypt(p_pin, gen_salt('bf')) where lower(username) = lower(trim(p_user));
  if not found then raise exception 'Player not found'; end if;
  return true;
end $$;

create or replace function admin_add_credits(p_admin text, p_user text, p_amount int, p_note text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare pid bigint; bal int;
begin
  perform _check_admin(p_admin);
  if coalesce(p_amount, 0) <= 0 then raise exception 'Amount must be more than 0'; end if;
  select id into pid from players where lower(username) = lower(trim(p_user)) for update;
  if pid is null then raise exception 'Player not found'; end if;
  bal := _apply(pid, p_amount, 'topup', null, coalesce(nullif(trim(p_note), ''), 'Credits added at counter'));
  return jsonb_build_object('credits', bal);
end $$;

create or replace function admin_adjust(p_admin text, p_user text, p_amount int, p_note text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare pid bigint; cur int; bal int;
begin
  perform _check_admin(p_admin);
  if coalesce(p_amount, 0) = 0 then raise exception 'Amount cannot be 0'; end if;
  select id, credits into pid, cur from players where lower(username) = lower(trim(p_user)) for update;
  if pid is null then raise exception 'Player not found'; end if;
  if cur + p_amount < 0 then raise exception 'Player only has % credits', cur; end if;
  bal := _apply(pid, p_amount, 'adjust', null, coalesce(nullif(trim(p_note), ''), 'Manual correction'));
  return jsonb_build_object('credits', bal);
end $$;

create or replace function admin_players(p_admin text, p_search text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare r jsonb;
begin
  perform _check_admin(p_admin);
  select coalesce(jsonb_agg(to_jsonb(x) order by lower(x.username)), '[]'::jsonb) into r from (
    select p.username, p.credits, p.created_at, p.status,
           coalesce(sum(t.amount) filter (where t.type = 'topup'), 0)::int as topped_up,
           coalesce(sum(t.amount) filter (where t.type = 'win'), 0)::int as won,
           coalesce(-sum(t.amount) filter (where t.type = 'game_fee'), 0)::int as spent,
           max(t.created_at) filter (where t.type = 'topup') as last_topup
      from players p left join transactions t on t.player_id = p.id
     where nullif(trim(p_search), '') is null or p.username ilike '%' || trim(p_search) || '%'
     group by p.id order by lower(p.username) limit 1000) x;
  return r;
end $$;

create or replace function admin_ledger(p_admin text, p_user text, p_type text, p_limit int)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare r jsonb;
begin
  perform _check_admin(p_admin);
  select coalesce(jsonb_agg(to_jsonb(x) order by x.id desc), '[]'::jsonb) into r from (
    select t.id, t.created_at, t.username, t.type, t.amount, t.balance_after,
           coalesce(g.name, t.game_id) as game, t.note
      from transactions t left join games g on g.id = t.game_id
     where (nullif(trim(p_user), '') is null or t.username ilike '%' || trim(p_user) || '%')
       and (nullif(p_type, '') is null or t.type = p_type)
     order by t.id desc limit least(coalesce(p_limit, 500), 5000)) x;
  return r;
end $$;

create or replace function admin_summary(p_admin text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _check_admin(p_admin);
  return jsonb_build_object(
    'players', (select count(*) from players),
    'credits_issued', (select coalesce(sum(amount), 0) from transactions where type = 'topup'),
    'credits_in_wallets', (select coalesce(sum(credits), 0) from players),
    'fees_collected', (select coalesce(-sum(amount), 0) from transactions where type = 'game_fee'),
    'paid_to_winners', (select coalesce(sum(amount), 0) from transactions where type = 'win'),
    'per_game', (select coalesce(jsonb_agg(to_jsonb(x) order by x.name), '[]'::jsonb) from (
        select coalesce(g.name, t.game_id) as name,
               count(*) filter (where t.type = 'game_fee')::int as plays,
               count(*) filter (where t.type = 'win')::int as wins,
               coalesce(-sum(t.amount) filter (where t.type = 'game_fee'), 0)::int as fees,
               coalesce(sum(t.amount) filter (where t.type = 'win'), 0)::int as payouts
          from transactions t left join games g on g.id = t.game_id
         where t.game_id is not null group by 1) x));
end $$;

create or replace function admin_save_game(p_admin text, p_id text, p_name text, p_desc text, p_price int, p_win int, p_enabled boolean, p_kind text)
returns boolean language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _check_admin(p_admin);
  if coalesce(p_price, -1) < 0 or coalesce(p_win, -1) < 0 then raise exception 'Price and winning amount must be 0 or more'; end if;
  if coalesce(trim(p_name), '') = '' then raise exception 'Game name is required'; end if;
  update games set name = trim(p_name), description = p_desc, price = p_price, win_amount = p_win, enabled = coalesce(p_enabled, true)
   where id = p_id;
  if not found then
    if p_kind is distinct from 'station' or p_id !~ '^st_[a-z0-9_]{1,30}$' then raise exception 'Can only add new station games'; end if;
    insert into games (id, name, kind, description, price, win_amount, enabled, sort)
    values (p_id, trim(p_name), 'station', p_desc, p_price, p_win, coalesce(p_enabled, true), 50);
  end if;
  return true;
end $$;

create or replace function admin_delete_game(p_admin text, p_id text)
returns boolean language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _check_admin(p_admin);
  delete from games where id = p_id and kind = 'station' and not exists (select 1 from game_sessions where game_id = p_id);
  if not found then raise exception 'Only station games can be deleted'; end if;
  return true;
end $$;

-- VR / PlayStation counter: action 'charge' takes the game price, 'win' pays the win amount (or p_amount)
create or replace function admin_station(p_admin text, p_user text, p_game text, p_action text, p_amount int)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare pid bigint; cur int; g games; amt int; bal int;
begin
  perform _check_admin(p_admin);
  select * into g from games where id = p_game and kind = 'station';
  if not found then raise exception 'Station game not found'; end if;
  select id, credits into pid, cur from players where lower(username) = lower(trim(p_user)) for update;
  if pid is null then raise exception 'Player not found'; end if;
  if p_action = 'charge' then
    if not g.enabled then raise exception 'This game is closed'; end if;
    if cur < g.price then raise exception 'Player has only % credits (needs %)', cur, g.price; end if;
    bal := _apply(pid, -g.price, 'game_fee', g.id, g.name);
    return jsonb_build_object('credits', bal, 'msg', 'Charged ' || g.price::text || ' credits');
  elsif p_action = 'win' then
    amt := coalesce(p_amount, g.win_amount);
    if amt <= 0 then raise exception 'Win amount must be more than 0'; end if;
    bal := _apply(pid, amt, 'win', g.id, g.name || ' winner');
    return jsonb_build_object('credits', bal, 'msg', 'Paid ' || amt::text || ' credits');
  end if;
  raise exception 'Unknown action';
end $$;

create or replace function admin_add_question(p_admin text, p_mode text, p_level int, p_q text, p_c text, p_w1 text, p_w2 text, p_w3 text)
returns boolean language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _check_admin(p_admin);
  if p_mode not in ('quiz', 'kbc') then raise exception 'Mode must be quiz or kbc'; end if;
  if p_mode = 'kbc' and (p_level < 1 or p_level > 10) then raise exception 'KBC level must be 1 to 10'; end if;
  if coalesce(trim(p_q), '') = '' or coalesce(trim(p_c), '') = '' or coalesce(trim(p_w1), '') = ''
     or coalesce(trim(p_w2), '') = '' or coalesce(trim(p_w3), '') = '' then
    raise exception 'Fill the question and all 4 options';
  end if;
  perform _add_question(p_mode, case when p_mode = 'kbc' then p_level else 1 end, trim(p_q), trim(p_c), trim(p_w1), trim(p_w2), trim(p_w3));
  return true;
end $$;

-- ------------------------------------------------------------ SEED DATA
-- admin password (only set the first time)  <<< CHANGE ME  (or change later in the Admin > Settings tab)
insert into settings (key, value)
values ('admin_hash', extensions.crypt('CHANGE_THIS_ADMIN_PASSWORD_BEFORE_RUNNING', extensions.gen_salt('bf')))
on conflict (key) do nothing;

-- TEMPORARY prices (credits to play) and winning amounts (credits won). Change anytime in the Admin page.
insert into games (id, name, kind, description, price, win_amount, sort) values
  ('quiz',   'Quiz Master',          'digital', '8 MCQs. Get 6 right to win.',                              10, 25, 1),
  ('kbc',    'Kaun Banega 100 Pati', 'digital', '10 questions, climb the prize ladder. 50-50 lifeline!',    20, 100, 2),
  ('guess',  'Guess the Number',     'digital', 'Find the secret number (1-100) in 6 tries using hints.',   10, 25, 3),
  ('maze',   'Maze Runner',          'digital', 'Reach the exit in 75 seconds.',                            10, 25, 4),
  ('puzzle', 'Sliding Puzzle',       'digital', 'Solve the 8-puzzle in 2 minutes.',                         10, 25, 5),
  ('math',   'Math Sprint',          'digital', '8 sums in 75 seconds. Get 7 right.',                       10, 25, 6),
  ('memory', 'Memory Match',         'digital', 'Match all 8 pairs of symbols.',                              3, 0, 7),
  ('ttt',    'Tic-Tac-Toe',          'digital', 'Play X against the computer.',                                3, 0, 8),
  ('vr',     'VR Experience',        'station', 'Played at the VR counter. Staff will charge your credits.', 30, 50, 10),
  ('ps',     'PlayStation Challenge','station', 'Played at the PS counter. Beat the target to win.',         20, 40, 11)
on conflict (id) do nothing;

do $seed$
begin
  if not exists (select 1 from questions) then
    -- quiz questions
    perform _add_question('quiz',1,'Capital of Australia?','Canberra','Sydney','Melbourne','Perth');
    perform _add_question('quiz',1,'National animal of India?','Tiger','Lion','Elephant','Leopard');
    perform _add_question('quiz',1,'Largest planet in the Solar System?','Jupiter','Saturn','Neptune','Earth');
    perform _add_question('quiz',1,'Who wrote India''s national anthem?','Rabindranath Tagore','Bankim Chandra Chatterjee','Sarojini Naidu','Premchand');
    perform _add_question('quiz',1,'Chemical symbol of gold?','Au','Ag','Gd','Go');
    perform _add_question('quiz',1,'Taj Mahal is in which city?','Agra','Delhi','Jaipur','Lucknow');
    perform _add_question('quiz',1,'Hardest natural substance?','Diamond','Iron','Quartz','Granite');
    perform _add_question('quiz',1,'Currency of Japan?','Yen','Won','Yuan','Ringgit');
    perform _add_question('quiz',1,'How many continents are there?','7','5','6','8');
    perform _add_question('quiz',1,'Which gas do plants absorb for photosynthesis?','Carbon dioxide','Oxygen','Nitrogen','Helium');
    perform _add_question('quiz',1,'Fastest land animal?','Cheetah','Lion','Horse','Leopard');
    perform _add_question('quiz',1,'Largest Indian state by area?','Rajasthan','Madhya Pradesh','Maharashtra','Uttar Pradesh');
    perform _add_question('quiz',1,'Who is called the Missile Man of India?','A.P.J. Abdul Kalam','Vikram Sarabhai','Homi Bhabha','C.V. Raman');
    perform _add_question('quiz',1,'Capital of Rajasthan?','Jaipur','Jodhpur','Udaipur','Kota');
    perform _add_question('quiz',1,'Boiling point of water in degrees Celsius?','100','90','120','80');
    perform _add_question('quiz',1,'Which planet is called the Red Planet?','Mars','Venus','Mercury','Saturn');
    perform _add_question('quiz',1,'Smallest prime number?','2','1','3','0');
    perform _add_question('quiz',1,'Who painted the Mona Lisa?','Leonardo da Vinci','Pablo Picasso','Vincent van Gogh','Michelangelo');
    perform _add_question('quiz',1,'Largest ocean on Earth?','Pacific','Atlantic','Indian','Arctic');
    perform _add_question('quiz',1,'How many bones are in an adult human body?','206','196','216','250');
    perform _add_question('quiz',1,'Who won the FIFA World Cup in 2022?','Argentina','France','Brazil','Croatia');
    perform _add_question('quiz',1,'Who won the T20 World Cup in 2024?','India','South Africa','Australia','England');
    perform _add_question('quiz',1,'National flower of India?','Lotus','Rose','Marigold','Jasmine');
    perform _add_question('quiz',1,'The Thar Desert is mostly in which state?','Rajasthan','Gujarat','Punjab','Haryana');
    perform _add_question('quiz',1,'How many days are in a leap year?','366','365','364','367');
    perform _add_question('quiz',1,'Founder of Microsoft?','Bill Gates','Steve Jobs','Elon Musk','Larry Page');
    perform _add_question('quiz',1,'Square root of 144?','12','14','11','13');
    perform _add_question('quiz',1,'Which vitamin do we get from sunlight?','Vitamin D','Vitamin A','Vitamin C','Vitamin K');
    perform _add_question('quiz',1,'Largest mammal in the world?','Blue whale','Elephant','Giraffe','Hippopotamus');
    perform _add_question('quiz',1,'H2O is the formula of?','Water','Hydrogen','Salt','Oxygen');
    -- Kaun Banega 100 Pati: 2 questions per level, easy (1) to hard (10)
    perform _add_question('kbc',1,'How many days are there in a week?','7','5','6','8');
    perform _add_question('kbc',1,'Which colour is at the top of the Indian flag?','Saffron','Green','White','Blue');
    perform _add_question('kbc',2,'What is the national bird of India?','Peacock','Parrot','Sparrow','Crow');
    perform _add_question('kbc',2,'How many colours are there in a rainbow?','7','5','6','8');
    perform _add_question('kbc',3,'Who was the first Prime Minister of India?','Jawaharlal Nehru','Mahatma Gandhi','Sardar Patel','Rajendra Prasad');
    perform _add_question('kbc',3,'Which is the closest star to Earth?','The Sun','Sirius','Polaris','Alpha Centauri');
    perform _add_question('kbc',4,'Which is the smallest planet in our Solar System?','Mercury','Mars','Venus','Pluto');
    perform _add_question('kbc',4,'What is the capital of Punjab (India)?','Chandigarh','Ludhiana','Amritsar','Patiala');
    perform _add_question('kbc',5,'Who discovered the laws of gravity?','Isaac Newton','Albert Einstein','Galileo Galilei','Thomas Edison');
    perform _add_question('kbc',5,'Which is the largest organ of the human body?','Skin','Liver','Heart','Brain');
    perform _add_question('kbc',6,'Who is known as the Father of the Indian Constitution?','Dr B. R. Ambedkar','Jawaharlal Nehru','Mahatma Gandhi','Sardar Patel');
    perform _add_question('kbc',6,'The 2024 Summer Olympics were held in which city?','Paris','Tokyo','London','Los Angeles');
    perform _add_question('kbc',7,'Which Indian city is known as the Pink City?','Jaipur','Jodhpur','Udaipur','Jaisalmer');
    perform _add_question('kbc',7,'Who was the first Indian-born woman to go to space?','Kalpana Chawla','Sunita Williams','Indira Gandhi','Bachendri Pal');
    perform _add_question('kbc',8,'Which is the longest bone in the human body?','Femur','Humerus','Tibia','Spine');
    perform _add_question('kbc',8,'Chandrayaan-3 landed near which pole of the Moon?','South pole','North pole','East pole','West pole');
    perform _add_question('kbc',9,'The Battle of Plassey was fought in which year?','1757','1857','1764','1658');
    perform _add_question('kbc',9,'Which element has the atomic number 6?','Carbon','Oxygen','Nitrogen','Boron');
    perform _add_question('kbc',10,'Who was the first Indian to win a Nobel Prize?','Rabindranath Tagore','C. V. Raman','Mother Teresa','Amartya Sen');
    perform _add_question('kbc',10,'Which Indian state has the longest coastline?','Gujarat','Tamil Nadu','Maharashtra','Andhra Pradesh');
  end if;
end
$seed$;



create or replace function admin_set_status(p_admin text,p_user text,p_status text)
returns boolean language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _check_admin(p_admin);
  if p_status not in ('active','suspended') then raise exception 'Status must be active or suspended'; end if;
  update players set status=p_status where lower(username)=lower(trim(p_user));
  if not found then raise exception 'Player not found'; end if;
  return true;
end $$;
create or replace function admin_set_setting(p_admin text,p_key text,p_value text)
returns boolean language plpgsql security definer set search_path = public, extensions as $$
declare n int;
begin
  perform _check_admin(p_admin);
  raise exception 'Setting is not editable from this page';
end $$;
create or replace function photobooth_info(p_user text,p_pin text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare pl players; fee int;
begin
  pl := _auth_player(p_user,p_pin);
  select value::int into fee from settings where key='photobooth_fee';
  return jsonb_build_object('fee',greatest(0,coalesce(fee,15)),'credits',pl.credits);
end $$;

-- Simple completion endpoint for client-side casual games. These two games have no completion bonus by default.
create or replace function arcade_finish_simple(p_user text,p_pin text,p_session bigint,p_won boolean,p_msg text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare pl players; s game_sessions; res jsonb; bal int;
begin
  pl := _auth_player(p_user,p_pin);
  s := _get_session(pl.id,p_session,array['memory','ttt']);
  if s.status <> 'active' then return coalesce(s.result,jsonb_build_object('done',true,'won',false,'win',0,'msg','Game already finished')); end if;
  select credits into bal from players where id=pl.id;
  res := jsonb_build_object('done',true,'won',coalesce(p_won,false),'win',0,'msg',left(coalesce(p_msg,'Game finished.'),300),'balance',bal);
  update game_sessions set status=case when coalesce(p_won,false) then 'won' else 'lost' end,result=res,ended_at=now() where id=s.id;
  return res;
end $$;

-- ------------------------------------------------------------ LOCK EVERYTHING DOWN
alter table settings enable row level security;
alter table players enable row level security;
alter table games enable row level security;
alter table transactions enable row level security;
alter table questions enable row level security;
alter table game_sessions enable row level security;

revoke all on settings, players, games, transactions, questions, game_sessions from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;

-- only the public API functions (names not starting with _) may be called from the browser
do $grants$
declare r record;
begin
  for r in
    select p.oid::regprocedure as sig, p.proname
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.prokind = 'f'
       and p.proowner = (select oid from pg_roles where rolname = current_user)
  loop
    execute format('revoke all on function %s from public, anon, authenticated', r.sig);
    if r.proname !~ '^_' then
      execute format('grant execute on function %s to anon, authenticated', r.sig);
    end if;
  end loop;
end
$grants$;


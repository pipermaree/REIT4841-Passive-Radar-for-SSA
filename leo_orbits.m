function api = leo_orbits()
%LEO_ORBITS  TLE and orbit processing: CelesTrak / SATCAT download and caching,
%   TLE and SATCAT parsing, object selection, RCS lookup, SGP4 positions and passes
%   with satelliteScenario.
%   Returns handles to its functions, e.g. X = leo_orbits(); X.elevAngle(...).
%   Part of the LEO passive-radar planner (main file: leo_detectability.m).
    persistent A
    if isempty(A)
        A = struct( ...
            'elevAngle', @elevAngle,  ...
            'filterTerms', @filterTerms,  ...
            'loadData', @loadData,  ...
            'objectRCS', @objectRCS,  ...
            'orbitAccess', @orbitAccess,  ...
            'orbitStates', @orbitStates,  ...
            'selectObjects', @selectObjects);
    end
    api = A;
end

function [tle, scat] = loadData(cfg, say)
    UTL = leo_utils();
    if strcmpi(cfg.source, 'celestrak')
        f = fetchCelestrakTLE(cfg.groups, cfg.cacheHours);
        if ~isempty(cfg.satcatFile)
            cfg.satcatFile = UTL.modelPath(cfg.satcatFile);
            cachedDownload('https://celestrak.org/pub/satcat.csv', cfg.satcatFile, cfg.satcatCacheHours);
        end
    else
        f = cfg.tleFile;
        if ~isfile(f) && isfile(UTL.modelPath(f)), f = UTL.modelPath(f); end
        if ~isempty(cfg.satcatFile) && ~isfile(cfg.satcatFile), cfg.satcatFile = UTL.modelPath(cfg.satcatFile); end
    end
    tle  = readTLE(f);
    scat = readSatcat(cfg.satcatFile);
    say('%d objects loaded from %s\n', numel(tle.name), f);
end

function idx = selectObjects(tle, cfg)
% LEO objects, optionally restricted to the NORAD ids in cfg.norad and/or
% names matching cfg.nameFilter (an object is kept if it matches either).
    idx = find(tle.meanAltKm < cfg.maxAltKm & tle.ecc < 0.25);
    terms = filterTerms(cfg.nameFilter);
    if isempty(cfg.norad) && isempty(terms), return; end
    keep = false(size(idx));
    if ~isempty(cfg.norad)
        want = regexprep(strtrim(string(cfg.norad)), '^0+', '');
        have = regexprep(string(tle.norad(idx)), '^0+', '');
        keep = keep | ismember(have, want);
    end
    if ~isempty(terms)
        nm = upper(string(tle.name(idx)));
        for t = 1:numel(terms)
            try
                hit = ~cellfun(@isempty, regexp(cellstr(nm), upper(terms{t}), 'once'));
            catch                                  % not a valid regexp: plain text
                hit = contains(nm, upper(terms{t}));
            end
            keep = keep | hit(:);
        end
    end
    idx = idx(keep);
    if isempty(idx)
        what = strjoin([string(cfg.norad(:)).' string(terms)], ', ');
        error('No LEO objects match %s in the TLE data (check the spelling, the CelesTrak groups or the TLE file).', what);
    end
end

function terms = filterTerms(f)
    if isempty(f), terms = {}; return; end
    terms = strtrim(strsplit(char(f), {',', ';'}));
    terms = terms(~cellfun(@isempty, terms));
end

function f = fetchCelestrakTLE(groups, cacheHours)
% Download each CelesTrak group (cached), merge into one TLE file, drop duplicates.
    UTL = leo_utils();
    f = UTL.modelPath('celestrak_merged.tle');          % caches live next to this file, whatever the current folder
    seen = containers.Map('KeyType','char','ValueType','logical');
    fid = fopen(f, 'w');  nTot = 0;  anyFail = false;
    for g = 1:numel(groups)
        grp = lower(groups{g});
        url = sprintf('https://celestrak.org/NORAD/elements/gp.php?GROUP=%s&FORMAT=tle', grp);
        local = UTL.modelPath(sprintf('celestrak_%s.tle', regexprep(grp, '[^a-z0-9-]', '_')));
        [ok, connFail] = cachedDownload(url, local, cacheHours, ~anyFail);
        anyFail = anyFail || connFail;
        if ~ok, continue; end
        t = readTLE(local);
        if isempty(t.name)
            warning('CelesTrak group "%s" returned no TLEs (check the group name).', grp);
        end
        for k = 1:numel(t.name)
            if isKey(seen, t.norad{k}), continue; end
            seen(t.norad{k}) = true;  nTot = nTot + 1;
            fprintf(fid, '%s\n%s\n%s\n', t.name{k}, t.l1{k}, t.l2{k});
        end
    end
    fclose(fid);
    fprintf('CelesTrak: %d unique objects from %d groups\n', nTot, numel(groups));
    if anyFail
        warning(['Could not reach celestrak.org, so remaining downloads were skipped (cached copies used where present). ' ...
                 'Check a proxy under Preferences > Web, try webread(''https://celestrak.org''), ' ...
                 'or set in.source = ''file'' with a TLE file downloaded in a browser.']);
    end
    if nTot == 0
        error(['No TLEs available: no cached copies in %s and the CelesTrak download failed (see the warning above ' ...
               'for the reason). If it says 403/Forbidden, CelesTrak has temporarily blocked this connection for ' ...
               'downloading too often: wait 2 hours. Otherwise check the internet connection or a proxy ' ...
               '(Preferences > Web). Meanwhile, download a TLE file in a browser and set Orbit data > Source ' ...
               'to TLE file (in a script: cfg.source = ''file'', cfg.tleFile = ''yourfile.tle'').'], ...
              fileparts(f));
    end
end

function [ok, connFail] = cachedDownload(url, local, maxAgeHours, tryNet)
% Use the local copy if it is younger than maxAgeHours; otherwise download.
% CelesTrak usage policy: only HTTP 200 counts, retry at most twice, and
% keep using the cached copy if the download fails. If the server can't be
% reached at all (tryNet = false after a failure), don't try again this run.
    if nargin < 4, tryNet = true; end
    ok = false;  connFail = false;  msg = 'not attempted (CelesTrak unreachable earlier in this run)';
    if isfile(local)
        d = dir(local);
        if (now - d.datenum)*24 < maxAgeHours, ok = true; return; end
    end
    opts = weboptions('Timeout', 60);
    for attempt = 1:2*tryNet
        try
            tmp = [local '.part'];
            websave(tmp, url, opts);
            movefile(tmp, local, 'f');
            fprintf('Downloaded %s\n', url);
            ok = true;  return
        catch err
            if isfile([local '.part']), delete([local '.part']); end
            msg = err.message;
            if contains(msg, {'connect', 'resolve', 'Could not'}, 'IgnoreCase', true)
                connFail = true;  break            % network problem: retrying won't help
            end
        end
    end
    if isfile(local)
        warning('Download failed (%s); using cached %s.', msg, local);  ok = true;
    else
        warning('Download failed (%s); skipping %s.', msg, url);
    end
end

function tle = readTLE(fname)
% Parse a 2- or 3-line TLE file.
    L = splitlines(string(fileread(fname)));  L = strtrim(L);  L(L == "") = [];
    tle = struct('name',{{}}, 'norad',{{}}, 'l1',{{}}, 'l2',{{}});
    k = 0;  i = 1;
    while i < numel(L)
        if startsWith(L(i), "1 ") && startsWith(L(i+1), "2 ")
            k = k + 1;
            if i > 1 && ~startsWith(L(i-1), "1 ") && ~startsWith(L(i-1), "2 ")
                nm = regexprep(char(L(i-1)), '^0 ', '');
            else
                nm = sprintf('NORAD %s', strtrim(extractBetween(L(i), 3, 7)));
            end
            tle.name{k} = strtrim(nm);  tle.l1{k} = char(L(i));  tle.l2{k} = char(L(i+1));
            tle.norad{k} = strtrim(tle.l1{k}(3:7));
            i = i + 2;
        else
            i = i + 1;
        end
    end
    n = numel(tle.name);
    tle.epoch = repmat(datetime(2000,1,1,'TimeZone','UTC'), 1, n);
    [tle.inc, tle.raan, tle.ecc, tle.argp, tle.M0, tle.n, tle.ndot2] = deal(zeros(1,n));
    for k = 1:n
        l1 = tle.l1{k};  l2 = tle.l2{k};
        yy = str2double(l1(19:20));  doy = str2double(l1(21:32));
        tle.ndot2(k) = str2double(l1(34:43));            % (dn/dt)/2, rev/day^2
        yr = 2000 + yy;  if yy >= 57, yr = 1900 + yy; end
        tle.epoch(k) = datetime(yr,1,1,'TimeZone','UTC') + days(doy - 1);
        tle.inc(k)  = str2double(l2(9:16));
        tle.raan(k) = str2double(l2(18:25));
        tle.ecc(k)  = str2double(['0.' strtrim(l2(27:33))]);
        tle.argp(k) = str2double(l2(35:42));
        tle.M0(k)   = str2double(l2(44:51));
        tle.n(k)    = str2double(l2(53:63));            % rev/day
    end
    mu = 3.986004418e14;
    a = (mu ./ (tle.n*2*pi/86400).^2).^(1/3);
    tle.meanAltKm = (a - 6378137) / 1e3;
end

function S = readSatcat(fname)
% CelesTrak SATCAT: NORAD id -> RCS (m^2) and object type.
    S = struct('rcs', containers.Map('KeyType','char','ValueType','double'), ...
                 'type', containers.Map('KeyType','char','ValueType','char'));
    if isempty(fname) || ~isfile(fname), return; end
    T = readtable(fname, 'TextType','char');
    for i = 1:height(T)
        key = strtrim(num2str(T.NORAD_CAT_ID(i)));
        S.type(key) = char(T.OBJECT_TYPE(i));
        r = T.RCS(i);  if iscell(r), r = str2double(r{1}); end
        if ~isnan(r) && r > 0, S.rcs(key) = r; end
    end
    fprintf('SATCAT: %d objects, %d with RCS\n', height(T), S.rcs.Count);
    % median published RCS per object type: used for objects SATCAT gives no RCS for
    S.medRCS = containers.Map('KeyType','char','ValueType','double');
    r = T.RCS;  if iscell(r), r = str2double(r); end
    typ = string(T.OBJECT_TYPE);
    for t = ["PAY", "R/B", "DEB", "UNK"]
        v = r(typ == t & r > 0 & ~isnan(r));
        if numel(v) >= 20, S.medRCS(char(t)) = median(v); end
    end
end

function [rcs, src, typ] = objectRCS(norad, name, scat, rcsDefault, rcsOverride, rules)
% Order: hand override > SATCAT RCS > name rule (assumed) > default by type.
    key = regexprep(norad, '^0+', '');
    if isKey(scat.type, key), typ = scat.type(key);
    elseif contains(upper(name), 'R/B'), typ = 'R/B';
    elseif contains(upper(name), 'DEB'), typ = 'DEB';
    else, typ = 'PAY';
    end
    if isKey(rcsOverride, key)
        ov = rcsOverride(key);
        if iscell(ov), rcs = ov{1};  src = ['override: ' ov{2}];
        else,          rcs = ov;     src = 'override';
        end
    elseif isKey(scat.rcs, key),  rcs = scat.rcs(key);    src = 'SATCAT';
    elseif ~isempty(ruleMatch(name, rules))
        j = ruleMatch(name, rules);  rcs = rules{j,2};
        src = sprintf('rule %s (%s)', regexprep(rules{j,1}, '[\^\$]', ''), rules{j,3});
    elseif isKey(rcsDefault, typ), rcs = rcsDefault(typ); src = ['default ' typ];
    else, rcs = rcsDefault('UNK');  src = 'default UNK';
    end
end

function j = ruleMatch(name, rules)
    j = [];
    for i = 1:size(rules, 1)
        if ~isempty(regexpi(name, rules{i,1}, 'once')), j = i; return; end      % case-insensitive
    end
end

function pos = orbitStates(tle, idx, tUTC)
% SGP4 positions (ECEF, m) from satelliteScenario for TLE entries idx at the
% uniformly spaced UTC times tUTC: nT x 3 x n. Done in chunks to limit memory.
    nT = numel(tUTC);  n = numel(idx);  pos = zeros(nT, 3, n);
    if n == 0, return; end
    if nT < 2, error('orbitStates needs at least two times.'); end
    dt = seconds(tUTC(2) - tUTC(1));  chunk = 200;
    for c0 = 1:chunk:n
        j = c0:min(c0 + chunk - 1, n);
        % keep sc: deleting the scenario invalidates its satellites
        [sc, sats, ok] = orbitScenario(tle, idx(j), tUTC(1), tUTC(end), dt); %#ok<ASGLU>
        pos(:, :, j(~ok)) = NaN;                               % TLEs SGP4 could not use
        if any(ok)
            jo = j(ok);
            p = states(sats, 'CoordinateFrame', 'ecef');       % 3 x nS x m
            p = reshape(p, 3, size(p, 2), []);
            m = min(nT, size(p, 2));
            pos(1:m, :, jo) = permute(p(:, 1:m, :), [2 1 3]);
            if m < nT, pos(m+1:end, :, jo) = repmat(pos(m, :, jo), nT - m, 1); end
        end
        clear sats sc
    end
end

function [pos, iv] = orbitAccess(tle, idx, tUTC, rx)
% SGP4 positions at tUTC (as orbitStates) plus the passes over the receiver from
% satelliteScenario access(): iv has Obj (index into idx), StartTime, EndTime (UTC).
    [sc, sats, ok] = orbitScenario(tle, idx, tUTC(1), tUTC(end), seconds(tUTC(2) - tUTC(1)));
    nT = numel(tUTC);  pos = NaN(nT, 3, numel(idx));
    iv = table(zeros(0,1), NaT(0,1,'TimeZone','UTC'), NaT(0,1,'TimeZone','UTC'), ...
               'VariableNames', {'Obj','StartTime','EndTime'});
    if ~any(ok), return; end
    jo = find(ok);
    p = states(sats, 'CoordinateFrame', 'ecef');
    p = reshape(p, 3, size(p, 2), []);
    m = min(nT, size(p, 2));
    pos(1:m, :, jo) = permute(p(:, 1:m, :), [2 1 3]);
    if m < nT, pos(m+1:end, :, jo) = repmat(pos(m, :, jo), nT - m, 1); end
    gs = groundStation(sc, rx.lat, rx.lon, 'MinElevationAngle', 0);
    A = accessIntervals(access(sats, gs));
    if isempty(A) || height(A) == 0, return; end
    obj = str2double(extractAfter(string(A.Source), 'OBJ_'));
    t0 = A.StartTime;  t1 = A.EndTime;
    if isempty(t0.TimeZone), t0.TimeZone = 'UTC';  t1.TimeZone = 'UTC'; end
    iv = table(obj, t0, t1, 'VariableNames', {'Obj','StartTime','EndTime'});
    iv = iv(isfinite(iv.Obj), :);
end

function [sc, sats, ok] = orbitScenario(tle, idx, t0, t1, dt)
% satelliteScenario with one SGP4 satellite per TLE entry in idx. Satellites are
% named OBJ_<i> (i = position in idx), so results map back to the TLE list even
% when catalogue names repeat (e.g. debris). ok(i) is false for a TLE that
% satelliteScenario refuses (e.g. a decayed object or a malformed line): such
% entries are skipped and the rest are kept, in order.
    UTL = leo_utils();
    if ~UTL.hasFcn('satelliteScenario')
        error(['Orbits use satelliteScenario (Aerospace Toolbox or Satellite Communications Toolbox, ' ...
               'R2021a or later), which is not available. Run ver to see your toolboxes.']);
    end
    t0.TimeZone = 'UTC';  t1.TimeZone = 'UTC';  t0.TimeZone = '';  t1.TimeZone = '';
    sc = satelliteScenario(t0, t1, dt);
    sc.AutoSimulate = true;
    ok = false(numel(idx), 1);
    [sats, ok] = addSats(sc, tle, idx, 1:numel(idx), ok);
    if any(~ok)
        warning('leo:tleSkipped', '%d of %d TLEs could not be added to the scenario and were skipped.', ...
                sum(~ok), numel(ok));
    end
end

function [sats, ok] = addSats(sc, tle, idx, ids, ok)
% Add the TLEs at positions ids in one go; if satelliteScenario refuses, split
% the group in two and retry, so only the bad entries are left out.
    sats = [];
    if isempty(ids), return; end
    f = [tempname '.tle'];  fid = fopen(f, 'w');
    for i = ids
        fprintf(fid, 'OBJ_%d\n%s\n%s\n', i, strtrim(tle.l1{idx(i)}), strtrim(tle.l2{idx(i)}));
    end
    fclose(fid);
    cleanup = onCleanup(@() deleteIfFile(f)); %#ok<NASGU>
    try
        sats = satellite(sc, f, 'OrbitPropagator', 'sgp4');
        ok(ids) = true;
    catch
        if numel(ids) == 1, return; end
        h = floor(numel(ids)/2);
        [s1, ok] = addSats(sc, tle, idx, ids(1:h), ok);
        [s2, ok] = addSats(sc, tle, idx, ids(h+1:end), ok);
        sats = [s1, s2];
    end
end

function deleteIfFile(f)
    if isfile(f), delete(f); end
end

function el = elevAngle(pos, site, up)
% Elevation (deg) of positions pos (nT x 3 [x n]) seen from site.
    v = pos - site;
    el = asind(sum(v .* up, 2) ./ vecnorm(v, 2, 2));
    el = reshape(el, size(pos,1), []);
end

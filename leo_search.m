function api = leo_search()
%LEO_SEARCH  Searches built on the model: ranking objects in a window, pass
%   search, best capture sites, altitude curves and the candidate plots.
%   Returns handles to its functions, e.g. X = leo_search(); X.altitudeCurves(...).
%   Part of the LEO passive-radar planner (main file: leo_detectability.m).
    persistent A
    if isempty(A)
        A = struct( ...
            'altitudeCurves', @altitudeCurves,  ...
            'bestSite', @bestSite,  ...
            'findPasses', @findPasses,  ...
            'rankObjects', @rankObjects);
    end
    api = A;
end

function out = rankObjects(cfg, tle, scat, rx, rcv, C, M, md, P, say)
    ORB = leo_orbits();  RAD = leo_radar();  UTL = leo_utils();
    tLoc = cfg.start + seconds(0:cfg.dt:seconds(cfg.duration));
    tUTC = tLoc;  tUTC.TimeZone = 'UTC';
    cand = ORB.selectObjects(tle, cfg);
    [rxE, rxUp] = UTL.wgs84(rx.lat, rx.lon, 0);
    out = struct('mode','rank', 'table',table(), 'res',[], 'tLoc',tLoc, 'rx',rx, 'rcv',rcv, 'cfg',cfg);
    if numel(tUTC) < 2, error('The capture window must be longer than one time step.'); end
    % 1) quick visibility screen: SGP4 every <= 30 s (satelliteScenario), with a 2 deg margin
    stepS = min(30, seconds(tUTC(end) - tUTC(1)) / 2);
    tS = tUTC(1) + seconds(0:stepS:seconds(tUTC(end) - tUTC(1)));
    elS = ORB.elevAngle(ORB.orbitStates(tle, cand, tS), rxE, rxUp);
    vis = cand(max(elS, [], 1) >= cfg.minEl - 2);
    % 2) every time step for those
    pos = ORB.orbitStates(tle, vis, tUTC);
    if ~isempty(vis)
        keepV = max(ORB.elevAngle(pos, rxE, rxUp), [], 1) >= cfg.minEl;
        vis = vis(keepV);  pos = pos(:,:,keepV);
    end
    say('%s to %s: %d of %d candidate objects reach %g deg elevation (SGP4, satelliteScenario)\n', char(tLoc(1)), ...
        char(string(tLoc(end),'HH:mm:ss')), numel(vis), numel(cand), cfg.minEl);
    if isempty(vis), return; end

    % RCS for every visible object, then merge objects flying together
    % (e.g. ISS modules with their own catalogue numbers): keep the largest.
    nV0 = numel(vis);
    rcsV = zeros(nV0,1);  srcV = cell(nV0,1);  typV = cell(nV0,1);
    for v = 1:nV0
        k = vis(v);
        [rcsV(v), srcV{v}, typV{v}] = ORB.objectRCS(tle.norad{k}, tle.name{k}, scat, md.rcsDefault, md.rcsOverride, md.rcsRules);
    end
    mid = max(1, round(size(pos,1)/2));
    pm  = reshape(pos(mid,:,:), 3, []).';
    keep = true(nV0,1);  nMerged = zeros(nV0,1);
    [~, ordR] = sort(rcsV, 'descend');
    for a = ordR.'
        if ~keep(a), continue; end
        same = find(keep & vecnorm(pm - pm(a,:), 2, 2) < cfg.mergeKm*1e3);
        same(same == a) = [];
        keep(same) = false;  nMerged(a) = numel(same);
    end
    if any(~keep)
        say('Merged %d objects flying with larger ones (e.g. docked modules)\n', sum(~keep));
    end
    vis = vis(keep);  pos = pos(:,:,keep);  rcsV = rcsV(keep);  srcV = srcV(keep);  typV = typV(keep);  nMerged = nMerged(keep);
    nV = numel(vis);
    res = repmat(struct('snr',[],'rngEx',[],'dop',[],'el',[],'B',[],'Tc',[],'chName','','win',1,'detMask',[],'base',0), nV, 1);
    tab = table('Size',[nV 17], 'VariableTypes', ...
        {'string','string','string','double','string','double','datetime','double','double','string','double','double','double','logical', ...
         'datetime','datetime','double'}, ...
        'VariableNames', {'Name','NORAD','Type','RCS_m2','RCS_source','EqRadius_m','PeakTime','MaxEl_deg', ...
        'MinRange_km','BestChannel','PeakSNR_1s','TrackSNR','TrackWindow_s','Detectable', ...
        'DetectFrom','DetectTo','DetectTime_s'});
    tab.PeakTime.TimeZone = tLoc.TimeZone;  tab.DetectFrom.TimeZone = tLoc.TimeZone;  tab.DetectTo.TimeZone = tLoc.TimeZone;
    for v = 1:nV
        k = vis(v);
        rcs = rcsV(v);  src = srcV{v};  typ = typV{v};
        req = sqrt(rcs/pi);
        p  = pos(:,:,v);
        nm = string(tle.name{k});
        if nMerged(v) > 0, nm = nm + sprintf(' [+%d attached]', nMerged(v)); end
        el = ORB.elevAngle(p, rxE, rxUp);
        b  = RAD.bestChannel(p, el, req, C, M, rxE, rcv, P, cfg.dt);
        [~, iPk] = max(b.snr);
        rng = vecnorm(p - rxE, 2, 2) / 1e3;
        [dFrom, dTo, dDur, mask] = detectInterval(b.snr, cfg.dt, b.win, P.kSigma, tLoc);
        chNm = UTL.chanName(md.ch(C.idx(b.q),:));
        if isfield(b, 'nCh') && b.nCh > 1, chNm = sprintf('%s + %d more', chNm, b.nCh - 1); end
        tab(v,:) = {nm, string(tle.norad{k}), string(typ), rcs, string(src), req, ...
                    tLoc(iPk), max(el), min(rng(el > 0)), string(chNm), ...
                    max(b.snr), b.d, b.win, b.d >= P.kSigma, dFrom, dTo, dDur};
        res(v).snr = b.snr;  res(v).rngEx = b.rngEx;  res(v).dop = b.dop;  res(v).el = el;
        res(v).B = C.B(b.q);  res(v).chName = chNm;  res(v).win = b.win;  res(v).detMask = mask;
        res(v).base = C.base(b.q);  res(v).lam = C.lam(b.q);
        res(v).Tc = C.Tc(b.q);
    end
    [tab, ord] = sortrows(tab, 'TrackSNR', 'descend');
    out.table = tab;  out.res = res(ord);
    try, writetable(tab, cfg.outFile); catch, end
    say('%s at %s: %d of %d visible objects detectable at %g sigma (table: %s)\n', rcv.name, rx.name, ...
        sum(tab.Detectable), nV, P.kSigma, cfg.outFile);
    if cfg.plot, plotCandidates(out, P, cfg.topN, cfg.axes); end
end

function [tFrom, tTo, dur, mask] = detectInterval(snr, dt, win, kSigma, t)
% Span of the recording containing a detection: every sample inside a
% window (length win) whose integrated S/N reaches kSigma.
    snr = snr(:);  n = numel(snr);  t = t(:);
    N = min(max(1, round(win/dt)), n);
    cnt = movsum(ones(n,1), N);
    dc  = movsum(snr, N) * dt ./ sqrt(cnt * dt);
    lo = floor(N/2);  hi = N - 1 - lo;          % movsum window: lo before, hi after
    mask = false(n, 1);
    for i = find(dc >= kSigma).'
        mask(max(1, i-lo) : min(n, i+hi)) = true;
    end
    dur = sum(mask) * dt;
    tFrom = t(1);  tTo = t(1);
    if any(mask)
        tFrom = t(find(mask, 1));  tTo = t(find(mask, 1, 'last'));
    else
        tFrom(1) = NaT;  tTo(1) = NaT;
    end
end

function out = findPasses(cfg, tle, scat, rx, rcv, C, M, md, P, say)
% Passes over cfg.searchDays with predicted detectability.
%   cfg.norad given  -> every pass of those objects above cfg.minEl.
%   cfg.norad empty  -> ISS, unless cfg.allPasses = true: then all LEO
%                       objects, listing only passes predicted detectable.
    ORB = leo_orbits();  RAD = leo_radar();  UTL = leo_utils();
    chosen = ~isempty(cfg.norad) || ~isempty(ORB.filterTerms(cfg.nameFilter));
    allMode = ~chosen && cfg.allPasses;
    if ~chosen && ~allMode
        cfg.norad = {'25544'};
        say('No objects chosen: finding ISS passes.\n');
    end
    objs = ORB.selectObjects(tle, cfg);
    if chosen && numel(objs) > cfg.maxListObjects      % e.g. every Starlink: too many to list every pass
        allMode = true;
        say('%d objects match; listing only their predicted-detectable passes.\n', numel(objs));
    end
    [rxE, rxUp] = UTL.wgs84(rx.lat, rx.lon, 0);
    step = cfg.searchStep;
    if allMode, step = max(step, 30); end
    tC  = cfg.start + seconds(0:step:cfg.searchDays*86400);
    tCu = tC;  tCu.TimeZone = 'UTC';
    gMax = 6.5;                 % largest track-integration gain (wide beam, 60-90 s)
    vn = {'Name','NORAD','Rise','Peak','Set','MaxEl_deg','MinRange_km','RCS_m2','RCS_source', ...
          'BestChannel','PeakSNR_1s','TrackSNR','TrackWindow_s','Detectable', ...
          'DetectFrom','DetectTo','DetectTime_s'};
    rows = cell(0, numel(vn));  peakPos = zeros(0, 3);
    if allMode
        chunk = 50;
        say('Searching %d LEO objects over %g days (%g s steps); this can take several minutes...\n', ...
            numel(objs), cfg.searchDays, step);
    else
        chunk = max(1, numel(objs));
    end
    nScreen = 0;  nFull = 0;  tStart = tic;
    for c0 = 1:chunk:numel(objs)
        idx = objs(c0:min(c0+chunk-1, numel(objs)));
        % SGP4 states and passes (rise/set above the horizon) from satelliteScenario access()
        [pos, iv] = ORB.orbitAccess(tle, idx, tCu, rx);       % pos nT x 3 x n; iv: Obj, StartTime, EndTime (UTC)
        el  = ORB.elevAngle(pos, rxE, rxUp);                  % nT x n
        for r = 1:height(iv)
                jj = iv.Obj(r);  k = idx(jj);
                seg = find(tCu >= iv.StartTime(r) & tCu <= iv.EndTime(r));
                if isempty(seg), [~, seg] = min(abs(tCu - iv.StartTime(r))); end
                if max(el(seg,jj)) < cfg.minEl - 2, continue; end      % coarse samples can miss the peak
                [rcs, src, ~] = ORB.objectRCS(tle.norad{k}, tle.name{k}, scat, md.rcsDefault, md.rcsOverride, md.rcsRules);
                req = sqrt(rcs/pi);
                nScreen = nScreen + 1;
                if allMode            % quick upper bound from the coarse samples
                    pk = 0;
                    for q = 1:numel(C.idx)
                        snr = RAD.objectSignal(pos(seg,:,jj), req, C, q, M, rxE, P, step);
                        pk  = max(pk, max(snr));
                    end
                    if pk * gMax * sqrt(P.nChanSum) < P.kSigma, continue; end
                end
                tFu = (iv.StartTime(r) - seconds(2)) : seconds(1) : (iv.EndTime(r) + seconds(2));
                p   = ORB.orbitStates(tle, k, tFu);
                elF = ORB.elevAngle(p, rxE, rxUp);
                if max(elF) < cfg.minEl, continue; end
                nFull = nFull + 1;
                tF  = tFu;  tF.TimeZone = cfg.start.TimeZone;     % local time for the table
                b   = RAD.bestChannel(p, elF, req, C, M, rxE, rcv, P, 1);
                if allMode && b.d < P.kSigma, continue; end
                [mx, ip] = max(elF);
                rng = vecnorm(p - rxE, 2, 2) / 1e3;
                [dFrom, dTo, dDur] = detectInterval(b.snr, 1, b.win, P.kSigma, tF);
                rows(end+1,:) = {string(tle.name{k}), string(tle.norad{k}), tF(find(elF > 0, 1)), tF(ip), ...
                                 tF(find(elF > 0, 1, 'last')), mx, min(rng(elF > 0)), rcs, string(src), ...
                                 string(UTL.chanName(md.ch(C.idx(b.q),:))) + RAD.nMore(b), max(b.snr), b.d, b.win, b.d >= P.kSigma, ...
                                 dFrom, dTo, dDur}; %#ok<AGROW>
                peakPos(end+1,:) = p(ip,:);                                                            %#ok<AGROW>
        end
        if allMode && mod((c0-1)/chunk + 1, 40) == 0
            say('  %d of %d objects searched (%.0f s)\n', min(c0+chunk-1, numel(objs)), numel(objs), toc(tStart));
        end
    end
    if isempty(rows)
        T = cell2table(cell(0, numel(vn)), 'VariableNames', vn);
    else
        T = cell2table(rows, 'VariableNames', vn);
        % merge passes of objects flying together (e.g. ISS modules): keep the largest
        keep = true(height(T), 1);
        [~, o] = sort(T.RCS_m2, 'descend');
        for a = o.'
            if ~keep(a), continue; end
            same = find(keep & abs(seconds(T.Peak - T.Peak(a))) <= max(step, 10) & ...
                        vecnorm(peakPos - peakPos(a,:), 2, 2) < cfg.mergeKm*1e3);
            same(same == a) = [];
            keep(same) = false;
            if ~isempty(same), T.Name(a) = T.Name(a) + sprintf(' [+%d attached]', numel(same)); end
        end
        T = sortrows(T(keep,:), 'Peak');
    end
    if allMode
        say('%d passes screened, %d modelled in full, %d predicted detectable (%.0f s)\n', ...
            nScreen, nFull, height(T), toc(tStart));
    else
        say('%d passes above %g deg in %g days from %s (%s, %s)\n', height(T), cfg.minEl, cfg.searchDays, ...
            char(cfg.start), rcv.name, rx.name);
        if height(T) > 0, say('%d predicted detectable at %g sigma\n', sum(T.Detectable), P.kSigma); end
    end
    out = struct('mode','passes', 'passes',T, 'rx',rx, 'rcv',rcv, 'cfg',cfg);
end

function plotCandidates(out, P, topN, axIn)
    tab = out.table;  res = out.res;  tLoc = out.tLoc;
    n = min(topN, height(tab));
    if isempty(axIn)
        figure('Color','w', 'Position', [40 40 1400 820]);
        tl = tiledlayout(2, 2, 'TileSpacing','compact', 'Padding','compact');
        title(tl, sprintf('Top %d candidates: %s at %s, %s', n, out.rcv.name, out.rx.name, char(tLoc(1))));
        axIn = gobjects(1,4);
        for i = 1:4, axIn(i) = nexttile(tl); end
    end
    ttl = {'Elevation at receiver (deg)', 'Snapshot S/N (1 s, best channel)', ...
           'Bistatic range excess (km)', 'Doppler (Hz)'};
    hdr = {'Elevation of the object above the receiver''s horizon', ...
           'Signal-to-noise per 1 s frame (best channel)', ...
           'Bistatic range excess: echo path minus direct path', ...
           'Doppler shift of the echo'};
    cm = lines(max(n,1));
    for pnl = 1:4
        ax = axIn(pnl);  legend(ax, 'off');  delete(allchild(ax));   % also removes hidden lines (cla does not)
        set(ax, 'YScale','linear', 'XLimMode','auto', 'YLimMode','auto');
        hold(ax,'on');  box(ax,'on');  grid(ax,'on');
        for v = 1:n
            switch pnl
                case 1, y = res(v).el;
                case 2, y = res(v).snr;
                case 3, y = res(v).rngEx;
                case 4, y = res(v).dop;
            end
            y = y(:);
            if pnl > 1, y(res(v).snr <= 0) = NaN; end
            plot(ax, tLoc, y, '-', 'Color', cm(v,:), 'LineWidth', 1.4, ...
                 'DisplayName', sprintf('%s (track S/N %.2g)', tab.Name(v), tab.TrackSNR(v)));
        end
        if n > 0 && any(res(1).detMask)           % detectable span of the top object
            m = res(1).detMask(:);
            switch pnl
                case 1, y = res(1).el(:);
                case 2, y = res(1).snr(:);
                case 3, y = res(1).rngEx(:);
                case 4, y = res(1).dop(:);
            end
            y(~m) = NaN;
            plot(ax, tLoc, y, '-', 'Color', [0.85 0.1 0.1], 'LineWidth', 3.5, ...
                 'DisplayName', sprintf('Data inside a %g s window reaching %g\x03c3 (%s)', ...
                                        tab.TrackWindow_s(1), P.kSigma, tab.Name(1)));
        end
        if pnl == 1
            ylim(ax, [0 90]);
        end
        if pnl == 2
            set(ax, 'YScale','log');
            yline(ax, P.kSigma, 'k:', sprintf('Detection threshold, single 1 s snapshot (%g\\sigma)', P.kSigma), ...
                  'HandleVisibility','off');
            if n > 0 && tab.TrackWindow_s(1) > 1
                w = tab.TrackWindow_s(1);
                yline(ax, P.kSigma/sqrt(w), 'r--', ...
                      sprintf('Average S/N needed over %g s (%g\x03c3 integrated)', w, P.kSigma), ...
                      'Color', [0.8 0.1 0.1], 'HandleVisibility','off', 'Interpreter','none', ...
                      'LabelHorizontalAlignment','left');
            end
        end
        ylabel(ax, ttl{pnl});  xlabel(ax, 'Local time');
        title(ax, hdr{pnl}, 'FontWeight','normal');
        if pnl == 1 && n > 0
            legend(ax, 'Location','northoutside', 'NumColumns', 2, 'FontSize', 7, 'Interpreter','none');
        end
        hold(ax, 'off');
    end
end

function out = bestSite(cfg, md, P, say)
% Best capture location for each band (FM, DAB+, DTV) within the area the
% transmitter data covers. Each band uses an antenna for that band (below) with
% your SDR, amplifier and cable. Score = best channel's S/N per 1 s frame for a
% 1 m^2 object 500 km straight overhead (the Site map's OverheadSNR_1m2), which
% weighs illumination against direct-path interference, swamping and noise. Every point
% uses the same noise class (rural) because land use is not known; access is not
% considered. Free-space search on a 0.05 deg grid, then the best 5 candidates per
% band (on land, >= 15 km apart) re-checked with Longley-Rice terrain.
% The result is saved and reused, so it is the same every time.
    INP = leo_inputs();  RAD = leo_radar();  TER = leo_terrain();  UTL = leo_utils();
    f = cfg.bestSiteFile;  if isempty(f), f = UTL.modelPath('best_site.mat'); end
    if ~cfg.recompute && isfile(f)
        S = load(f, 'out');
        if isfield(S, 'out') && isfield(S.out, 'version') && S.out.version >= 3   % older files are redone
            out = S.out;  out.file = f;
            for b = 1:numel(out.bands)
                say('Best %s site (saved %s): %.4f, %.4f, %.1f dB via %s\n', out.bands(b).band, ...
                    char(out.computed), out.bands(b).bestLat, out.bands(b).bestLon, out.bands(b).score_dB, ...
                    out.bands(b).channel);
            end
            return
        end
    end
    % one antenna per band: Antenna Toolbox models of the antennas you have
    ant = struct('band', {'FM', 'DAB+', 'DTV'}, 'code', {'FM', 'DR', 'DTV'}, ...
                 'name', {'Half-wave FM dipole (100 MHz)', 'Digitek 01EDAB DAB+ folded dipole (flat)', ...
                          'Digitek 01BUWX16L UHF Yagi'}, ...
                 'antModel', {'dipole', 'dipoleFolded', 'yagi'}, 'designMHz', {100, 205.5, 606}, ...
                 'nElements', {1, 1, 16}, 'pol', {'H', 'H', 'H'});
    % DAB+ dipole mounted flat (horizontal): vertical, it has a null straight up
    hw = cfg.custom;  if isempty(hw), hw = INP.defaultHardware(); end
    % The transmitter list covers 150 km around Cooby Creek and UQ St Lucia. Further
    % out, stations are missing and the area looks falsely quiet, so only points whose
    % surroundings out to 75 km are covered are scored.
    ctr = [-27.39602 151.93897; -27.49753 153.01328];  reach = 150 - 75;  step = 0.05;
    la = min(ctr(:,1)) - reach/111 : step : max(ctr(:,1)) + reach/111;
    lo = min(ctr(:,2)) - reach/98  : step : max(ctr(:,2)) + reach/98;
    [LO, LA] = meshgrid(lo, la);
    dmin = inf(size(LA));
    for k = 1:size(ctr,1)
        dk = 6371 * acos(min(1, sind(LA)*sind(ctr(k,1)) + cosd(LA)*cosd(ctr(k,1)).*cosd(LO - ctr(k,2))));
        dmin = min(dmin, dk);
    end
    covered = dmin <= reach;  idx = find(covered);
    env = 'rural';  P0 = P;  P0.terrain = false;
    bands = struct('band', {}, 'antenna', {}, 'bestLat', {}, 'bestLon', {}, 'score_dB', {}, 'channel', {}, ...
                   'candidates', {}, 'atEdge', {}, 'score', {});
    for b = 1:numel(ant)
        c = hw;
        for fn = {'name', 'antModel', 'designMHz', 'nElements', 'pol'}, c.(fn{1}) = ant(b).(fn{1}); end
        [~, rcv, mdB] = INP.siteReceiver(struct('name','grid', 'lat',ctr(1,1), 'lon',ctr(1,2), 'env',env), 'custom', md, c);
        rcv.A.boreAz = cfg.antAz;  rcv.A.boreEl = cfg.antEl;
        say('Best %s site (%s): %d locations, free space; done once and saved...\n', ant(b).band, ...
            rcv.name, numel(idx));
        sc = NaN(size(LA));  t0 = tic;
        for ii = 1:numel(idx)
            i = idx(ii);
            r = struct('name', sprintf('grid %.4f, %.4f', LA(i), LO(i)), 'lat', LA(i), 'lon', LO(i), 'env', env);
            v = bandScore(RAD.channelSetup(r, mdB.ch, rcv, mdB.sdr, mdB.lna, mdB.cable, mdB.proc, P0), ant(b).code);
            if v > 0, sc(i) = 10*log10(v); end
            if mod(ii, 200) == 0, say('  %s: %d of %d locations (%.0f s)\n', ant(b).band, ii, numel(idx), toc(t0)); end
        end
        if all(~isfinite(sc(:)))
            say('  No %s channel gives any signal with this antenna.\n', ant(b).band);  continue
        end
        [~, ord] = sort(sc(:), 'descend', 'MissingPlacement', 'last');
        pick = [];
        for i = ord'
            if ~isfinite(sc(i)), break; end
            if ~isempty(pick) && any(111 * hypot(LA(pick) - LA(i), (LO(pick) - LO(i)) * cosd(LA(i))) < 15), continue; end
            if ~TER.onLand(LA(i), LO(i)), continue; end
            pick(end+1) = i; %#ok<AGROW>
            if numel(pick) >= 5, break; end
        end
        n = numel(pick);
        Lat = LA(pick)';  Lon = LO(pick)';  FreeSpace_dB = sc(pick)';  WithTerrain_dB = NaN(n,1);  BestChannel = strings(n,1);
        for j = 1:n
            r = struct('name', sprintf('Map site %.4f, %.4f (%s)', Lat(j), Lon(j), env), 'lat', Lat(j), 'lon', Lon(j), 'env', env);
            [v, nm] = bandScore(RAD.channelSetup(r, mdB.ch, rcv, mdB.sdr, mdB.lna, mdB.cable, mdB.proc, P), ant(b).code);
            WithTerrain_dB(j) = 10*log10(max(v, 1e-30));  BestChannel(j) = nm;
            say('  %s candidate %d: %.4f, %.4f  %.1f dB with terrain (free space %.1f dB) via %s\n', ant(b).band, ...
                j, Lat(j), Lon(j), WithTerrain_dB(j), FreeSpace_dB(j), nm);
        end
        T = sortrows(table(Lat, Lon, WithTerrain_dB, FreeSpace_dB, BestChannel), 'WithTerrain_dB', 'descend');
        % on the edge of the covered area? then the score may still rise further out
        [~, ib] = min(hypot(LA(:) - T.Lat(1), LO(:) - T.Lon(1)));  [r0, c0] = ind2sub(size(LA), ib);
        nb = covered(max(1,r0-1):min(end,r0+1), max(1,c0-1):min(end,c0+1));
        bands(end+1) = struct('band', ant(b).band, 'antenna', rcv.name, 'bestLat', T.Lat(1), 'bestLon', T.Lon(1), ...
                              'score_dB', T.WithTerrain_dB(1), 'channel', T.BestChannel(1), 'candidates', T, ...
                              'atEdge', ~all(nb(:)), 'score', sc); %#ok<AGROW>
        say('Best %s site: %.4f, %.4f, %.1f dB via %s (%.0f s)\n', ant(b).band, T.Lat(1), T.Lon(1), ...
            T.WithTerrain_dB(1), T.BestChannel(1), toc(t0));
    end
    if isempty(bands), error('Best-site search: no band gives any signal.'); end
    out = struct('mode','bestsite', 'version',3, 'bands',bands, 'env',env, 'computed',datetime('now'), ...
                 'gridLat',LA, 'gridLon',LO, ...
                 'note','S/N per 1 s frame, 1 m^2 object 500 km overhead; rural noise everywhere; access not considered');
    try, save(f, 'out'); catch err, warning('Could not save %s (%s).', f, err.message); end
    out.file = f;
end

function [v, nm] = bandScore(C, code)
% Best overhead S/N (linear) and its channel among this band's channels.
    T = C.all(string(C.all.Band) == code, :);  v = 0;  nm = "";
    if isempty(T), return; end
    [x, k] = max(T.OverheadSNR_1m2);
    if x > 0, v = x;  nm = T.Channel(k); end
end

function out = altitudeCurves(cfg, C, M, rx, rcv, md, P, say)
% S/N per 1 s frame against altitude for a PEC sphere straight along the
% receive antenna's boresight (default zenith), for every channel in the
% antenna band. Same calibration as the ranking: measured tx gain towards
% objects, ITU noise, terrain and polarisation.
    RAD = leo_radar();  UTL = leo_utils();
    h = cfg.altKm(:) * 1e3;
    [rxE, ~] = UTL.wgs84(rx.lat, rx.lon, P.rxHeight);
    up = rxE / norm(rxE);  Eo = cross([0 0 1], up);  Eo = Eo / norm(Eo);  No = cross(up, Eo);
    A = rcv.A;  bAz = UTL.fieldOr(A, 'boreAz', 0);  bEl = UTL.fieldOr(A, 'boreEl', 90);
    b = cosd(bEl)*sind(bAz)*Eo + cosd(bEl)*cosd(bAz)*No + sind(bEl)*up;
    R0 = norm(rxE);  bd = rxE * b';
    s = -bd + sqrt(bd^2 - R0^2 + (R0 + h).^2);         % range along the boresight to altitude h
    p = rxE + s .* b;
    req = cfg.radius;
    if ~isempty(cfg.rcs), req = sqrt(cfg.rcs/pi); end  % same conversion as the ranking
    C.dynTc = false;      % points along a vertical line, not a pass: use the reference-pass coherent time
    n = numel(C.idx);  snr = zeros(n, numel(h));  Sjy = zeros(n, numel(h));
    for q = 1:n
        if ~isfinite(C.noise(q)), continue; end       % SDR overloaded: nothing detectable
        snr(q,:) = RAD.objectSignal(p, req, C, q, M, rxE, P, 1).';
        Sjy(q,:) = snr(q,:) * C.noise(q);             % echo flux at the antenna (Jy, incl. pattern)
    end
    hMax = @(k) arrayfun(@(q) max([NaN; cfg.altKm(snr(q,:) >= k)']), (1:n)');
    T = C.all(1:n, {'Channel','MHz','Band','ERP_kW','Dist_km','TerrainLoss_dB','Swamping_dB','SDRin_dBm','Noise_Jy_1s'});
    T.TxSite = string(md.siteNames(cell2mat(C.rows(:,1))));
    T.Overloaded = ~isfinite(C.noise);
    T.MaxAlt_1sigma_km = hMax(1);  T.MaxAlt_3sigma_km = hMax(cfg.kSigma);
    T = movevars(T, 'TxSite', 'Before', 1);
    out = struct('mode','altitude', 'altKm',cfg.altKm(:)', 'snr',snr, 'Sjy',Sjy, 'noise',C.noise, ...
                 'noiseSweep',C.noiseSweep, 'cancelSweep',cfg.cancelSweep(:)', 'cancel_dB',md.proc.cancel_dB, ...
                 'table',T, 'rx',rx, 'rcv',rcv, 'radius',req, 'rcs',cfg.rcs, 'kSigma',cfg.kSigma, ...
                 'siteNames',{md.siteNames}, 'cfg',cfg);
    say('Altitude curves: %s, %d channels, equivalent sphere r = %.3g m\n', rx.name, n, req);
end

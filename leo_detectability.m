function out = leo_detectability(cfg)
% LEO_DETECTABILITY  Which LEO objects would be detectable in a passive-radar capture?
%
%   out = leo_detectability(cfg)   (all fields optional; see withDefaults below)
%
%   cfg.receiver = 'custom' with cfg.custom = hardware values (see siteReceiver).
%   cfg.trackWindow = 'auto' or a fixed integration window in seconds.
%
%   cfg.mode = 'rank'   : rank every object visible in a time window
%                         (cfg.start, cfg.duration), optionally only cfg.norad.
%   cfg.nameFilter = 'tiangong, hubble' : keep objects whose name matches any of the
%                         comma-separated terms (case-insensitive text or regexp);
%                         combined with cfg.norad as either/or.
%   cfg.mode = 'corrections' : table of the hand-set RCS values and name rules.
%   cfg.motionComp = true : orbit-based motion correction in the ranking (coherent 1 s).
%   cfg.blindSearch = true : the same coherent 1 s WITHOUT knowing the orbit (keystone
%                         transform + a bank of Doppler-rate trials), less the threshold
%                         rise from testing that many trials (for untracked objects).
%   cfg.nChanSum = N    : combine the N best channels of the antenna band (one capture).
%   cfg.arrayN = N      : N identical antennas beamformed (one SDR channel each).
%   cfg.mode = 'bestsite' : the best capture location for FM, DAB+ and DTV in the area
%                         covered by the transmitter data (one antenna per band, your
%                         SDR, amplifier and cable). Computed once and saved
%                         in best_site.mat next to this file; later calls load it
%                         (cfg.recompute = true to search again).
%   cfg.mode = 'site'   : direct-path interference at the site: per-channel table
%                         (with terrain) and a free-space map of total direct power.
%   cfg.mode = 'passes' : list passes of cfg.norad (default ISS, '25544'; or all LEO
%                         with cfg.allPasses = true, detectable passes only) over
%                         cfg.searchDays from cfg.start, each with its predicted
%                         detectability.
%
%   Examples
%     out = leo_detectability();                                   % defaults
%     out = leo_detectability(struct('norad',{{'25544'}}, ...
%              'start',datetime(2026,10,25,19,0,0,'TimeZone','Australia/Brisbane'), ...
%              'duration',minutes(20)));                           % ISS only
%     out = leo_detectability(struct('mode','passes','searchDays',7));  % ISS passes
%   Or run the interactive app: leo_app
%
% Model: same as realistic_setup.m (bistatic radar
% equation, Mie scattering of an equivalent conducting sphere from the
% catalogued RCS, antenna pattern, receiver noise, direct-path interference,
% integration along the pass).
%
% DATA (downloaded live from CelesTrak by default, cached locally)
%   TLEs:   https://celestrak.org/NORAD/elements/gp.php?GROUP=<group>&FORMAT=tle
%   SATCAT: https://celestrak.org/pub/satcat.csv (RCS in m^2 where available)
%   Or cfg.source = 'file' with cfg.tleFile.
% PROPAGATION
%   All orbits use MATLAB's satelliteScenario with the SGP4 propagator (Aerospace
%   Toolbox or Satellite Communications Toolbox, R2021a or later): states() for
%   positions and access()/accessIntervals() for passes. TLE accuracy still
%   limits predictions more than a few days from the TLE epoch: re-run with
%   fresh TLEs before a capture.
    INP = leo_inputs();  ORB = leo_orbits();  RAD = leo_radar();  SCH = leo_search();  UTL = leo_utils();

    if nargin < 1, cfg = struct(); end
    if isfield(cfg, 'mode') && strcmpi(cfg.mode, 'assumptions')  % workbook contents for the app's Assumptions tab
        f = '';  if isfield(cfg, 'inputFile'), f = cfg.inputFile; end
        md = INP.modelSetup(f);
        out = struct('assume', md.assume, 'file', md.inputFile);
        return
    end
    if isfield(cfg, 'mode') && strcmpi(cfg.mode, 'txlist')      % transmitter masts, for the map
        f = '';  if isfield(cfg, 'inputFile'), f = cfg.inputFile; end
        md = INP.modelSetup(f);
        if isfield(cfg, 'txSet') && strcmpi(cfg.txSet, 'original'), md.ch = md.chOriginal; end
        out = INP.txSites(md.ch);  return
    end
    if isfield(cfg, 'mode') && strcmpi(cfg.mode, 'corrections')
        f = '';  if isfield(cfg, 'inputFile'), f = cfg.inputFile; end
        out = INP.listCorrections(INP.modelSetup(f));  return
    end
    cfg = INP.withDefaults(cfg);
    say = cfg.log;
    md  = INP.modelSetup(cfg.inputFile);
    say('Inputs: %s\n', md.inputFile);
    P   = md.P;  P.kSigma = cfg.kSigma;
    site = cfg.site;
    if strncmpi(site, 'custom', 6)                   % a site picked on the map
        if isnan(cfg.siteLat) || isnan(cfg.siteLon), error('Custom site needs cfg.siteLat and cfg.siteLon.'); end
        site = struct('name', sprintf('Map site %.4f, %.4f (%s)', cfg.siteLat, cfg.siteLon, cfg.siteEnv), ...
                      'lat', cfg.siteLat, 'lon', cfg.siteLon, 'env', lower(cfg.siteEnv));
    end
    [rx, rcv, md] = INP.siteReceiver(site, cfg.receiver, md, cfg.custom);
    md.sdr.bw_MHz = cfg.sdrBW_MHz;  md.sdr.filtRej_dB = cfg.filterRej_dB;
    if strcmpi(cfg.txSet, 'original')
        md.ch = md.chOriginal;  md.siteNames = md.siteNamesOriginal;
        say('Transmitters: your original four sites (%d channels)\n', size(md.ch,1));
    else
        say('Transmitters: all FM/DAB+/DTV within 150 km, ERP >= 500 W (ACMA; %d channels at %d sites)\n', ...
            size(md.ch,1), numel(md.siteNames));
    end
    rcv.fp = sprintf('%s|tx:%s|wb:%s', rcv.fp, lower(cfg.txSet), md.inputStamp);   % workbook edits refresh the model
    rcv.A.boreAz = cfg.antAz;  rcv.A.boreEl = cfg.antEl;
    if ~isempty(cfg.rxPol), rcv.A.pol = upper(cfg.rxPol(1)); end
    rcv.fp = sprintf('%s|bore:%g,%g|pol:%s', rcv.fp, cfg.antAz, cfg.antEl, rcv.A.pol);
    P.txVertical = lower(cfg.txVertical);  P.daRxAtten_dB = cfg.daRxAtten_dB;
    if ~ismember(P.txVertical, {'paper','measured'}), error('cfg.txVertical must be ''paper'' or ''measured''.'); end
    P.cancelMethod = lower(char(cfg.cancelMethod));
    if ~ismember(P.cancelMethod, {'fixed','eca'}), error('cfg.cancelMethod must be ''fixed'' or ''eca''.'); end
    rcv.fp = sprintf('%s|cancel:%s', rcv.fp, P.cancelMethod);
    [P.txPat, patMsg] = INP.loadTxPatterns(cfg.txPatternFile, md.txPatSheet);
    if ~isempty(patMsg), say('%s\n', patMsg); end
    rcv.fp = sprintf('%s|bw:%g|filt:%g|vert:%s|da:%g|pat:%d', rcv.fp, cfg.sdrBW_MHz, cfg.filterRej_dB, ...
                     P.txVertical, cfg.daRxAtten_dB, P.txPat.Count);
    if ~isempty(cfg.excludeTx)
        drop = ismember(upper(string(md.ch(:,6))), upper(string(cfg.excludeTx))) | ...
               ismember(upper(string(md.ch(:,9))), upper(string(cfg.excludeTx)));
        md.ch = md.ch(~drop, :);
        rcv.fp = sprintf('%s|excl:%s', rcv.fp, char(strjoin(upper(string(cfg.excludeTx)), ',')));
        say('Excluding transmitters: %s\n', char(strjoin(string(cfg.excludeTx), ', ')));
    end
    if ~isempty(cfg.rcsRules)          % user rules replace a default rule with the same pattern, else go first
        for i = size(cfg.rcsRules, 1):-1:1
            j = find(strcmp(md.rcsRules(:,1), cfg.rcsRules{i,1}), 1);
            if isempty(j), md.rcsRules = [cfg.rcsRules(i,:); md.rcsRules];
            else,          md.rcsRules(j,:) = cfg.rcsRules(i,:);
            end
        end
    end
    if cfg.motionComp      % coherent over the full frame in every band
        P.motionComp = true;
        rcv.fp = sprintf('%s|mc', rcv.fp);
        say('Orbit-based motion correction: coherent integration over %g s in every band\n', P.tint);
    elseif cfg.blindSearch % the same without the orbit: keystone + Doppler-rate search
        P.motionComp = true;  P.blind = true;
        rcv.fp = sprintf('%s|blind:%g', rcv.fp, cfg.kSigma);   % search loss depends on the threshold
        say('Blind search (no orbit): keystone + Doppler-rate trials, coherent %g s, less the search loss\n', P.tint);
    end
    P.nChanSum = max(1, round(cfg.nChanSum));  P.arrayN = max(1, round(cfg.arrayN));
    P.maxChannels = max(P.maxChannels, P.nChanSum);
    rcv.fp = sprintf('%s|arr:%d|nch:%d', rcv.fp, P.arrayN, P.nChanSum);
    if P.arrayN > 1, say('Array: %d antennas beamformed (S/N x %d)\n', P.arrayN, P.arrayN); end
    if P.nChanSum > 1, say('Combining the %d best channels\n', P.nChanSum); end
    if isnumeric(cfg.trackWindow) && cfg.trackWindow >= 1
        P.trackLens = cfg.trackWindow;            % fixed integration window (s)
    end
    if strcmpi(cfg.mode, 'bestsite')  % fixed best capture location (computed once, then loaded)
        out = SCH.bestSite(cfg, md, P, say);  return
    end
    if strcmpi(cfg.mode, 'altitude')  % every channel in the band, each with terrain
        P.maxChannels = 1000;  P.cancelSweep = cfg.cancelSweep(:)';
        rcv.fp = sprintf('%s|allch|sweep:%s', rcv.fp, mat2str(P.cancelSweep));
    end
    [C, M] = RAD.cachedChannels(rx, rcv, md, P, say);
    if strcmpi(cfg.mode, 'altitude')  % S/N vs altitude straight up, per channel
        out = SCH.altitudeCurves(cfg, C, M, rx, rcv, md, P, say);  return
    end
    if strcmpi(cfg.mode, 'site')     % direct-path picture of this site; no orbits needed
        out = struct('mode','site', 'table',C.all, 'chosen',{UTL.chanNames(md.ch, C.idx)}, 'rx',rx, 'rcv',rcv, ...
                     'grid',RAD.dpiGrid(md, rcv, rx, cfg.gridHalfDeg), 'tx',INP.txSites(md.ch), 'cfg',cfg);
        say('Site analysed: %s, %d channels in the antenna band\n', rx.name, height(C.all));
        return
    end
    [tle, scat] = ORB.loadData(cfg, say);
    if isfield(scat, 'medRCS') && scat.medRCS.Count > 0     % defaults from SATCAT itself, not assumed
        k = keys(scat.medRCS);
        for i = 1:numel(k), md.rcsDefault(k{i}) = scat.medRCS(k{i}); end
        say('RCS when SATCAT has none: median of SATCAT by type (%s)\n', ...
            strjoin(cellfun(@(t) sprintf('%s %.2g m^2', t, scat.medRCS(t)), k, 'UniformOutput', false), ', '));
    end
    if ~isempty(tle.epoch)
        ageDays = abs(days(cfg.start - median(tle.epoch)));
        if ageDays > 7
            msg = sprintf(['Start time is %.0f days from the orbital data (TLE epoch %s). Predictions are reliable ' ...
                           'to about a week: objects and times this far out are not meaningful.'], ...
                          ageDays, char(median(tle.epoch), 'dd-MMM-yyyy'));
            say('WARNING: %s\n', msg);  warning(msg);
        end
    end
    switch lower(cfg.mode)
        case 'rank',   out = SCH.rankObjects(cfg, tle, scat, rx, rcv, C, M, md, P, say);
        case 'passes', out = SCH.findPasses(cfg, tle, scat, rx, rcv, C, M, md, P, say);
        otherwise, error(['Unknown cfg.mode "%s". This copy of leo_detectability supports: rank, passes, ' ...
                          'altitude, site, bestsite, txlist, corrections, assumptions.'], cfg.mode);
    end
end

%% ==================================================================

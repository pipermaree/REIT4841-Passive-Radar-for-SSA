function api = leo_inputs()
%LEO_INPUTS  Options and inputs: default options, the leo_inputs.xlsx workbook
%   (transmitters, assumptions, RCS corrections, patterns), the model setup and the
%   receiver (site and hardware).
%   Returns handles to its functions, e.g. X = leo_inputs(); X.defaultHardware(...).
%   Part of the LEO passive-radar planner (main file: leo_detectability.m).
    persistent A
    if isempty(A)
        A = struct( ...
            'defaultHardware', @defaultHardware,  ...
            'listCorrections', @listCorrections,  ...
            'loadTxPatterns', @loadTxPatterns,  ...
            'modelSetup', @modelSetup,  ...
            'siteReceiver', @siteReceiver,  ...
            'txSites', @txSites,  ...
            'withDefaults', @withDefaults);
    end
    api = A;
end

function cfg = withDefaults(cfg)
    tz = 'Australia/Brisbane';
    d.mode       = 'rank';
    d.start      = dateshift(datetime('now','TimeZone',tz), 'start', 'day') + hours(19);
    d.duration   = minutes(15);
    d.dt         = 1;                 % s, time step when ranking
    d.minEl      = 20;                % deg, object must reach this elevation
    d.maxAltKm   = 2000;              % LEO
    d.site       = 'Cooby Creek';     % 'Cooby Creek', 'UQ St Lucia' or 'Custom' (with siteLat/siteLon/siteEnv)
    d.siteLat    = NaN;               % custom site latitude (deg)
    d.siteLon    = NaN;               % custom site longitude (deg)
    d.siteEnv    = 'rural';           % custom site noise: 'quietrural', 'rural', 'residential', 'business'
    d.gridHalfDeg = 1.5;              % 'site' mode: half-width of the interference map (deg)
    d.bestSiteFile = '';              % 'bestsite' mode: saved result ('' = best_site.mat next to this file)
    d.recompute  = false;             % 'bestsite' mode: true = search again and overwrite the saved result
    d.receiver   = 'custom';          % your hardware (cfg.custom; empty = default dipole + Fobos)
    d.custom     = [];                % hardware struct for 'custom' (see siteReceiver)
    d.trackWindow = 'auto';           % 'auto' (best of 1-120 s) or a fixed window in s
    d.excludeTx  = {};                % callsigns or areas to leave out, e.g. {'4JJJ', 'Brisbane'}
    d.cancelMethod = 'fixed';         % direct-path cancellation: 'fixed' (cancel_dB on the Assumptions sheet)
                                      % or 'eca' (ECA-B, modelled per channel from reference quality and distortion)
    d.txVertical = 'paper';           % transmitter gain towards objects: 'paper' (Gtx = 0.5, Tingay 2013; default),
                                      % or 'measured' (-16 dB, LOFAR in Poland, Jedrzejewski 2025)
    d.txPatternFile = '';             % '' = Tx_patterns sheet of the workbook; or a CSV: key, az_deg, atten_dB
    d.daRxAtten_dB = 0;               % directional tx without pattern data: assumed dB less towards the receiver
    d.sdrBW_MHz  = 50;                % SDR capture bandwidth: every station inside it shares the ADC
    d.filterRej_dB = 0;               % filter in front of the SDR: rejection of the other stations (dB)
    d.rxPol      = '';                % receive antenna mounting 'H' or 'V' ('' = antenna default, H)
    d.inputFile  = '';                % Excel workbook with the data tables ('' = leo_inputs.xlsx next to this file)
    d.motionComp = false;             % true: orbit-based (TLE) motion correction, so every band sums
                                      % coherently over the whole 1 s frame (as Jedrzejewski et al.)
    d.blindSearch = false;            % true: coherent 1 s without the orbit (keystone + Doppler-rate
                                      % search), less the false-alarm cost of the search (untracked objects)
    d.nChanSum   = 1;                 % channels combined (best N in the antenna band, same capture)
    d.arrayN     = 1;                 % identical antennas beamformed towards the object
    d.antAz      = 0;                 % receive antenna pointing: azimuth (deg from north)
    d.antEl      = 90;                % and elevation (deg; 90 = straight up, as for satellites)
    d.radius     = 0.5;               % 'altitude' mode: sphere radius (m)
    d.rcs        = [];                % 'altitude' mode: RCS (m^2) instead of a radius, as for catalogued
                                      % objects (equivalent sphere sqrt(rcs/pi), Mie bistatic RCS)
    d.cancelSweep = [];               % 'altitude' mode: also give noise for these cancellations (dB)
    d.altKm      = 100:10:3000;       % 'altitude' mode: altitudes (km)
    d.txSet      = 'seq';             % 'seq' = every transmitter within 150 km (ACMA); 'original' = your four sites
    d.rcsRules   = [];                % name rules {regexp, m^2, note; ...}; [] = built-in
    d.mergeKm    = 5;                 % merge objects flying within this distance (docked modules)
    d.allPasses  = false;             % 'passes' mode with no NORAD ids: true = all LEO (detectable passes only)
    d.norad      = {};                % {} = all LEO; {'25544'} = ISS only
    d.nameFilter = '';                % e.g. 'tiangong, ^hubble'; '' = no name filter
    d.maxListObjects = 50;            % passes mode: more matches than this => list detectable passes only
    d.kSigma     = 3;                 % detection threshold (sigma)
    d.source     = 'celestrak';       % 'celestrak' or 'file'
    d.groups     = {'active', 'stations', 'fengyun-1c-debris', ...
                    'iridium-33-debris', 'cosmos-2251-debris'};
    d.cacheHours = 2;
    d.satcatCacheHours = 24;
    d.tleFile    = 'leo.tle';
    d.satcatFile = 'satcat.csv';
    d.searchDays = 7;                 % 'passes' mode
    d.searchStep = 10;                % s, coarse step when searching for passes
    d.topN       = 8;
    d.outFile    = 'leo_candidates.csv';
    d.plot       = true;
    d.axes       = [];                % 4 axes to plot into (used by leo_app)
    d.log        = @(varargin) fprintf(varargin{:});
    f = fieldnames(d);
    for i = 1:numel(f)
        if ~isfield(cfg, f{i}) || (isempty(cfg.(f{i})) && ~any(strcmp(f{i}, {'norad','nameFilter','axes','satcatFile','custom','excludeTx','rxPol','inputFile','txPatternFile','bestSiteFile'})))
            cfg.(f{i}) = d.(f{i});
        end
    end
    if ~isfield(cfg, 'rcs'), cfg.rcs = []; end
    if ~isfield(cfg, 'cancelSweep'), cfg.cancelSweep = []; end
    if isempty(cfg.start.TimeZone), cfg.start.TimeZone = tz; end
    if isnumeric(cfg.duration), cfg.duration = minutes(cfg.duration); end
    if ischar(cfg.norad) || isstring(cfg.norad), cfg.norad = cellstr(cfg.norad); end
end

function md = modelSetup(inputFile)
% Transmitters, receiver chain and detection settings.
    % Data tables live in the Excel workbook (edit it to change the model):
    % Transmitters, Original4, RCS_overrides, RCS_name_rules, Tx_patterns.
    UTL = leo_utils();
    if nargin < 1 || isempty(inputFile), inputFile = defaultInputFile(); end
    inp = loadInputs(inputFile);
    md.inputFile = inp.file;
    [md.ch, md.siteNames] = txTable(inp.tx);                 % all within 150 km (ACMA)
    [md.chOriginal, md.siteNamesOriginal] = txTable(inp.orig); % your four sites only
    % Fobos spec: 50 MHz-6 GHz, double-conversion heterodyne at VHF/UHF (one channel),
    % 14-bit ADC, 82 dB blocking dynamic range, 52 dB IQ image rejection (software).
    % Noise figure is not published: 8 dB ASSUMED.
    md.sdr   = struct('name','RigExpert Fobos SDR', 'NF',8, 'maxIn_dBm',10, 'DR',82, 'IRR',52);
    % imgSelf = 1: capture centred on the illuminator, so its own direct-signal image
    % (52 dB down, a mirror copy the canceller cannot remove) lands on it. Set 0 if you
    % tune off-centre so the image falls on an empty part of the band.
    md.sdr.imgSelf = 1;
    % Swamping: every station inside the capture bandwidth reaches the ADC; its
    % blocking dynamic range (82 dB, datasheet; taken per channel bandwidth) puts the
    % noise floor in each channel DR dB below their total power (set per run from
    % cfg.sdrBW_MHz / cfg.filterRej_dB).
    md.sdr.bw_MHz = 50;  md.sdr.filtRej_dB = 0;
    % ECA-B cancellation: ceiling from published real-data results (Colone et al. 2016: ~52 dB
    % theoretical cancellation on FM, ECA-B close to it), limited per channel, with a separate
    % reference antenna, by that antenna's S/N (computed from your antenna).
    md.P.eca = struct('ceiling_dB', 50);
    md.lna   = struct('on',false, 'NF',2, 'gain',20);       % no amplifier
    md.cable = struct('length',15, 'fMHz',[50 100 200 400 600 800], 'dBper100m',[4.6 6.6 9.5 13.5 16.5 19.0]);
    md.proc.cancel_dB = 30;                                  % calibrated on the St Lucia aircraft capture
    md.proc.decodeSNR = containers.Map({'FM','DR','DTV'}, {Inf, 10, 20});
    md.rcsDefault  = containers.Map({'PAY','R/B','DEB','UNK'}, {1, 5, 0.1, 0.5});   % m^2
    % Hand-set RCS by NORAD id and name rules: ASSUMED estimates from size,
    % except the ISS (quoted). Edit them in the workbook.
    md.rcsOverride = inp.rcsOverride;      % sheet RCS_overrides: NORAD -> {m^2, note}
    md.rcsRules    = inp.rcsRules;         % sheet RCS_name_rules: {regexp, m^2, note}
    md.txPatSheet  = inp.txPat;            % sheet Tx_patterns (azimuth patterns)
    md.P.Bband     = containers.Map({'FM','DR','DTV'}, {50e3, 1.536e6, 7e6});
    % Coherent time without motion correction, from physics (not assumed): the echo stays
    % in one range cell for (c/B)/|range rate| and in one Doppler cell for 1/sqrt(|Doppler
    % rate|); Tc = min(1 s, both). Per moment of each pass in objectSignal; for choosing the
    % channels it is evaluated for a reference pass (v = 7.6 km/s, 500 km overhead).
    md.P.motionComp = false;  md.P.blind = false;  md.P.vRef = 7600;  md.P.hRef = 500e3;
    md.P.nChanSum = 1;  md.P.arrayN = 1;
    md.P.tint      = 1;
    md.P.Gtx       = 0.5;              % 'paper' vertical pattern: gain towards the object vs ERP
    % Transmitter pattern options (set per run from cfg):
    md.P.txVertical = 'paper';         % 'paper' (Gtx above, default) or 'measured'
    % 'measured': gain towards the object vs ERP, calibrated on real ISS echoes:
    % Jedrzejewski et al. (2025, IET RSN 19:e70009), 3 Polish DAB+ transmitters + LOFAR
    % PL610, 13:49:34 on 4 Apr 2023. Measured S/N was 7-19 dB (mean ~13 dB) below
    % this model with Gtx = 0.5 and ISS RCS 400 m^2 => about -16 dB (+/-6 dB) for
    % objects 60-66 deg above the transmitters. Assumed LOFAR Aeff ~850 m^2, Tsys ~300 K.
    md.P.Gmeas_dB   = -16;
    md.P.daRxAtten_dB = 0;             % DA transmitter with no pattern data: assumed loss towards the receiver
    md.P.txPat = containers.Map();     % azimuth patterns loaded from cfg.txPatternFile
    md.P.trackLens = [1 5 10 20 30 60 90 120];
    md.P.maxChannels = 6;              % channels kept per run (more = slower ranking)
    md.P.terrain    = true;
    md.P.terrainMap = "gmted2010";
    md.P.climate    = "continental-subtropical";
    md.P.rxHeight   = 10;
    md.P.terrainCacheFile = UTL.modelPath('terrain_cache.mat');   % delete to recompute terrain
    md.P.terrainScreen_dB = 6;          % skip terrain for channels this far below the cut even at best
    md.P.echoXpol   = 0.5;              % echo on a crossed antenna (scrambled polarisation)
    md.siteEnv = containers.Map({'Cooby Creek','UQ St Lucia'}, {'rural','business'});
    % The workbook's Assumptions sheet overrides the values above.
    md = applyAssumptions(md, inp);
    md.inputStamp   = inp.stamp;
end

function [rx, rcv, md] = siteReceiver(site, receiver, md, c)
    UTL = leo_utils();
    if isstruct(site), rx = site; site = 'struct'; end
    switch site
        case 'struct'
        case 'Cooby Creek', rx = struct('name','Cooby Creek', 'lat',-27.39602, 'lon',151.93897, 'env',md.siteEnv('Cooby Creek'));
        case 'UQ St Lucia', rx = struct('name','UQ St Lucia', 'lat',-27.49753, 'lon',153.01328, 'env',md.siteEnv('UQ St Lucia'));
        otherwise, error('Unknown site "%s"', site);
    end
    if ~strcmp(receiver, 'custom'), error('Unknown receiver "%s" (only ''custom'').', receiver); end
    % Your hardware (the app's Hardware tab): name, antModel ('dipole', 'dipoleFolded',
    % 'yagi' or 'loop', an Antenna Toolbox model), designMHz, nElements (Yagi), pol
    % ('H'/'V'), sdrName, NF, DR, maxIn (dBm), IRR (dB), lnaOn, lnaNF, lnaGain,
    % cableLen (m), cable100 / cable600 (dB per 100 m), refSeparate.
    if isempty(c), c = defaultHardware(); end
    model = UTL.fieldOr(c, 'antModel', '');
    if ~ismember(model, {'dipole','dipoleFolded','yagi','loop'})
        error(['Hardware: antModel must be an Antenna Toolbox model (dipole, dipoleFolded, yagi or loop); ' ...
               'got "%s". Datasheet gain curves are no longer supported.'], model);
    end
    A = struct('name',char(string(c.name)), 'pol',UTL.fieldOr(c, 'pol', 'H'), 'model',model, ...
               'designMHz',UTL.fieldOr(c, 'designMHz', 0), 'nEl',UTL.fieldOr(c, 'nElements', 3));
    if A.designMHz <= 0, error('Hardware: set the design frequency for the %s model.', A.model); end
    % the band searched for transmitters; realized gain (mismatch away from the design frequency) falls off outside
    A.fMHz = A.designMHz * [0.7 1.4];
    md.sdr = struct('name',char(string(c.sdrName)), 'NF',c.NF, 'maxIn_dBm',c.maxIn, 'DR',c.DR, ...
                    'IRR',UTL.fieldOr(c, 'IRR', 52), 'imgSelf',md.sdr.imgSelf, ...
                    'bw_MHz',UTL.fieldOr(md.sdr, 'bw_MHz', 50), 'filtRej_dB',UTL.fieldOr(md.sdr, 'filtRej_dB', 0));
    md.lna = struct('on',logical(c.lnaOn), 'NF',c.lnaNF, 'gain',c.lnaGain);
    md.cable = struct('length',c.cableLen, 'fMHz',[100 600], 'dBper100m',[c.cable100 c.cable600]);
    md.proc.refSeparate = logical(UTL.fieldOr(c, 'refSeparate', false));
    rcv = struct('code',receiver, 'type','antenna', 'A',A, ...
                 'name',sprintf('%s + %s', A.name, md.sdr.name), 'fp',jsonencode(c));
end

function T = listCorrections(md)
% Hand-set RCS values (by NORAD id) and name rules, for the app's Objects list.
    k = keys(md.rcsOverride);  n = numel(k);  nr = size(md.rcsRules, 1);
    Kind = strings(n+nr,1);  Key = strings(n+nr,1);  Label = strings(n+nr,1);
    RCS_m2 = zeros(n+nr,1);  Note = strings(n+nr,1);
    for i = 1:n
        v = md.rcsOverride(k{i});
        if iscell(v), r = v{1}; nt = string(v{2}); else, r = v; nt = ""; end
        short = strtrim(extractBefore(nt + ",", ","));          % 'Tiangong, assumed ...' -> 'Tiangong'
        short = strtrim(regexprep(short, '\s*\(.*$', ''));
        Kind(i) = "norad";  Key(i) = k{i};  RCS_m2(i) = r;  Note(i) = nt;
        Label(i) = sprintf('%s (%s, %g m^2)', short, k{i}, r);
    end
    for j = 1:nr
        i = n + j;  pat = string(md.rcsRules{j,1});
        nm = regexprep(pat, '[\^\$]', '');  nm = upper(extractBefore(nm,2)) + lower(extractAfter(nm,1));
        Kind(i) = "name";  Key(i) = pat;  RCS_m2(i) = md.rcsRules{j,2};  Note(i) = string(md.rcsRules{j,3});
        Label(i) = sprintf('All %s (name rule, %g m^2)', nm, md.rcsRules{j,2});
    end
    T = table(Kind, Key, Label, RCS_m2, Note);
    T = [T(T.Kind=="norad",:); T(T.Kind=="name",:)];
    [~, o] = sort(T.RCS_m2(T.Kind=="norad"), 'descend');
    nn = sum(T.Kind=="norad");  T(1:nn,:) = T(o,:);
end

function [pat, msg] = loadTxPatterns(f, sheetT)
% Azimuth patterns: rows of key, azimuth (deg), attenuation (dB) relative to the
% maximum ERP. From a CSV if f is given, else the workbook's Tx_patterns sheet.
% key = 'SBS33 (Darling Downs)', a callsign, or an area served.
    pat = containers.Map();  msg = '';
    if ~isempty(f) && isfile(f)
        T = readtable(f, 'TextType', 'string', 'VariableNamingRule', 'preserve');  src = f;
    elseif ~isempty(f)
        msg = sprintf('Pattern file %s not found; using the workbook sheet', f);  T = sheetT;  src = 'Tx_patterns sheet';
    else
        T = sheetT;  src = 'Tx_patterns sheet';
    end
    if isempty(T) || height(T) == 0, return; end
    T.Properties.VariableNames(1:3) = {'key', 'az', 'att'};
    T = T(~ismissing(string(T.key)) & strlength(strtrim(string(T.key))) > 0, :);
    k = unique(upper(strtrim(string(T.key))));
    for i = 1:numel(k)
        r = T(upper(strtrim(string(T.key))) == k(i), :);
        [az, o] = sort(mod(double(r.az), 360));
        att = double(r.att);
        pat(char(k(i))) = [az, att(o)];
    end
    msg = strtrim([msg sprintf(' Transmitter azimuth patterns: %d loaded from %s', pat.Count, src)]);
end

function f = defaultInputFile()
    f = fullfile(fileparts(mfilename('fullpath')), 'leo_inputs.xlsx');
end

function inp = loadInputs(f)
% Read the data workbook (cached until the file changes).
    persistent cache
    if ~isfile(f)
        error(['Input workbook not found: %s\nPut leo_inputs.xlsx in the same folder as ' ...
               'leo_detectability.m, or set cfg.inputFile.'], f);
    end
    info = dir(f);  stamp = sprintf('%s|%.6f', f, info.datenum);
    if ~isempty(cache) && strcmp(cache.stamp, stamp), inp = cache.inp; return; end
    opts = {'TextType','string', 'VariableNamingRule','preserve'};
    inp.file = f;
    inp.tx   = readtable(f, 'Sheet', 'Transmitters', opts{:});
    inp.orig = readtable(f, 'Sheet', 'Original4', opts{:});
    ov = readtable(f, 'Sheet', 'RCS_overrides', opts{:});
    inp.rcsOverride = containers.Map();
    for i = 1:height(ov)
        key = regexprep(strtrim(string(ov.NORAD(i))), '^0+', '');
        if strlength(key) == 0 || ismissing(key), continue; end
        note = string(ov.Note(i));  if ismissing(note), note = ""; end
        inp.rcsOverride(char(key)) = {double(ov.RCS_m2(i)), char(note)};
    end
    ru = readtable(f, 'Sheet', 'RCS_name_rules', opts{:});
    ru = ru(~ismissing(string(ru.NamePattern)), :);
    inp.rcsRules = [cellstr(strtrim(string(ru.NamePattern))), num2cell(double(ru.RCS_m2)), ...
                    cellstr(fillmissing(string(ru.Note), 'constant', ""))];
    if isempty(inp.rcsRules), inp.rcsRules = cell(0, 3); end
    try
        inp.txPat = readtable(f, 'Sheet', 'Tx_patterns', opts{:});
    catch
        inp.txPat = table();
    end
    try                                   % Value holds numbers and words (e.g. rural): read as text
        io = detectImportOptions(f, 'Sheet', 'Assumptions', 'TextType', 'string', 'VariableNamingRule', 'preserve');
        io = setvartype(io, 'Value', 'string');
        inp.assume = readtable(f, io);
    catch
        inp.assume = readSheet(f, 'Assumptions', opts);
    end
    inp.stamp = sprintf('%.6f', info.datenum);
    cache = struct('stamp', stamp, 'inp', inp);
end

function [ch, siteNames] = txTable(T)
% Transmitter sheet -> cell rows used by the model:
% site no., MHz, ERP (W), lat, lon, callsign, band, antenna height (m), area,
% pattern (OD/DA), polarisation (H/V/M). Rows with Include = N are skipped.
    if ismember('Include', T.Properties.VariableNames)
        T = T(~strcmpi(strtrim(string(T.Include)), 'N'), :);
    end
    n = height(T);
    txt = @(v) cellstr(strtrim(fillmissing(string(v), 'constant', "")));
    pat = txt(T.Pattern);  pat(cellfun(@isempty, pat)) = {'OD'};
    pol = txt(T.Polarisation);  band = txt(T.Band);
    for i = 1:n
        if isempty(pol{i}), switch band{i}, case 'DTV', pol{i} = 'H'; case 'DR', pol{i} = 'V'; otherwise, pol{i} = 'M'; end, end
    end
    ch = [num2cell(double(T.SiteNo)), num2cell(double(T.MHz)), num2cell(double(T.ERP_W)), ...
          num2cell(double(T.Lat)), num2cell(double(T.Lon)), txt(T.Callsign), band, ...
          num2cell(double(T.AntennaHeight_m)), txt(T.Area), pat, pol];
    siteNames = unique(txt(T.SiteName), 'stable');
    if isempty(ch), error('No transmitters selected in the workbook (all rows have Include = N?)'); end
end

function T = txSites(ch)
% One row per transmitter mast: position, strongest ERP, number of channels, area.
    key = compose('%.4f,%.4f', [ch{:,4}]', [ch{:,5}]');
    [u, ~, j] = unique(key, 'stable');  n = numel(u);
    Lat = zeros(n,1);  Lon = zeros(n,1);  MaxERP_kW = zeros(n,1);  Channels = zeros(n,1);  Area = strings(n,1);
    for i = 1:n
        k = find(j == i);
        Lat(i) = ch{k(1),4};  Lon(i) = ch{k(1),5};  MaxERP_kW(i) = max([ch{k,3}]) / 1e3;
        Channels(i) = numel(k);
        if size(ch,2) >= 9, Area(i) = string(ch{k(1),9}); end
    end
    T = table(Lat, Lon, MaxERP_kW, Channels, Area);
end

function T = readSheet(f, sheet, opts)
% Read a sheet, or an empty table if it is missing.
    try
        T = readtable(f, 'Sheet', sheet, opts{:});
    catch
        T = table();
    end
end

function md = applyAssumptions(md, inp)
% Values from the workbook's Assumptions sheet (when present).
    A = inp.assume;
    if ~isempty(A) && height(A) > 0 && all(ismember({'Parameter','Value'}, A.Properties.VariableNames))
        key = strtrim(string(A.Parameter));  val = string(A.Value);
        num = str2double(val);
        get = @(k, d) pick(key, num, k, d);
        md.sdr.DR        = get('fobos_DR_dB', md.sdr.DR);
        md.sdr.maxIn_dBm = get('fobos_maxIn_dBm', md.sdr.maxIn_dBm);
        md.sdr.IRR       = get('fobos_IRR_dB', md.sdr.IRR);
        md.sdr.NF        = get('fobos_NF_dB', md.sdr.NF);
        md.sdr.imgSelf   = get('fobos_imgSelf', md.sdr.imgSelf);
        md.cable.length  = get('cable_length_m', md.cable.length);
        md.P.rxHeight    = get('rx_height_m', md.P.rxHeight);
        md.proc.cancel_dB = get('cancel_dB', md.proc.cancel_dB);
        md.P.Gmeas_dB    = get('tx_gain_object_dB', md.P.Gmeas_dB);
        md.P.Gtx         = get('paper_Gtx', md.P.Gtx);
        md.proc.decodeSNR = containers.Map({'FM','DR','DTV'}, {Inf, get('decode_DR_dB', md.proc.decodeSNR('DR')), ...
                    get('decode_DTV_dB', md.proc.decodeSNR('DTV'))});
        md.P.echoXpol    = get('echo_crosspol_factor', md.P.echoXpol);
        md.rcsDefault = containers.Map({'PAY','R/B','DEB','UNK'}, {get('rcs_default_PAY', md.rcsDefault('PAY')), ...
                    get('rcs_default_RB', md.rcsDefault('R/B')), get('rcs_default_DEB', md.rcsDefault('DEB')), ...
                    get('rcs_default_UNK', md.rcsDefault('UNK'))});
        md.P.eca.ceiling_dB = get('eca_ceiling_dB', md.P.eca.ceiling_dB);
        for k = find(startsWith(key, "env_"))'                     % site noise classes
            md.siteEnv(char(extractAfter(key(k), 4))) = char(lower(strtrim(val(k))));
        end
    end
    md.assume = A;
end

function v = pick(key, num, k, d)
    i = find(key == k, 1);
    if isempty(i) || ~isfinite(num(i)), v = d; else, v = num(i); end
end

function c = defaultHardware()
% Default: half-wave dipole designed at 100 MHz (FM band), mounted horizontally,
% into the RigExpert Fobos.
    c = struct('name','Default FM dipole', 'antModel','dipole', 'designMHz',100, 'nElements',1, ...
               'pol','H', 'sdrName','RigExpert Fobos', 'NF',8, 'DR',82, 'maxIn',10, ...
               'IRR',52, 'lnaOn',false, 'lnaNF',2, 'lnaGain',20, 'cableLen',15, 'cable100',6.6, 'cable600',16.5, ...
               'refSeparate',false);
end

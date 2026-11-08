function leo_app
% LEO_APP  Interactive planner for passive-radar detection of LEO objects.
%
%   leo_app
%
% Front end for leo_detectability.m (keep both files in the same folder).
% Choose a date, start time and duration, the receiving site and setup, and
% which objects to model (all of LEO, the ISS only, or a list of NORAD ids),
% then press Run. "Find passes" lists upcoming passes of the chosen objects
% (with All LEO: every predicted-detectable pass of any object); click a pass to
% load its time window, then press Run.
% Track window sets the integration along the pass. Your receiving hardware
% (antenna, SDR, amplifier, cable, cancellation) is set once in the Hardware tab;
% model assumptions are listed in the Assumptions tab (leo_inputs.xlsx).
% Requires MATLAB R2020b or later.

    tz = 'Australia/Brisbane';

    fig = uifigure('Name', 'LEO passive-radar planner', 'Position', [80 60 1450 860]);
    main = uigridlayout(fig, [1 2]);
    main.ColumnWidth = {340, '1x'};

    % ---------------- controls ----------------
    ctl = uigridlayout(main, [22 2]);
    ctl.ColumnWidth = {120, '1x'};
    ctl.RowHeight = [repmat({26}, 1, 20), {'1x'}, {26}];
    ctl.RowSpacing = 6;

    r = 0;
    r = r + 1;  head(ctl, r, 'Capture window');
    r = r + 1;  lab(ctl, r, 'Date');
    dp = uidatepicker(ctl, 'Value', dateshift(datetime('now'), 'start', 'day'), 'DisplayFormat', 'dd-MMM-yyyy');
    place(dp, r);
    r = r + 1;  lab(ctl, r, 'Start time (local)');
    tStart = uieditfield(ctl, 'text', 'Value', '19:00', 'Tooltip', 'HH:mm, Brisbane time');
    place(tStart, r);
    r = r + 1;  lab(ctl, r, 'Duration (min)');
    dur = uispinner(ctl, 'Limits', [1 1440], 'Value', 15, 'Step', 5);
    place(dur, r);

    r = r + 1;  head(ctl, r, 'Receiver');
    r = r + 1;  lab(ctl, r, 'Site');
    site = uidropdown(ctl, 'Items', {'Cooby Creek', 'UQ St Lucia', 'Custom (map)'}, ...
                      'ItemsData', {'Cooby Creek', 'UQ St Lucia', 'Custom'}, ...
                      'Tooltip', 'Custom (map): the location chosen on the Site map tab', ...
                      'ValueChangedFcn', @(~,~) onSiteChange());
    place(site, r);
    r = r + 1;  lab(ctl, r, 'Hardware');
    hwName = uibutton(ctl, 'Text', 'Default', 'Tooltip', 'Open the Hardware tab', ...
                      'ButtonPushedFcn', @(~,~) goHardware());
    place(hwName, r);

    r = r + 1;  head(ctl, r, 'Targets');
    r = r + 1;  lab(ctl, r, 'Objects');
    % Objects list: ISS, All LEO, every hand-corrected object and name rule from
    % leo_detectability (so new corrections appear here automatically), then free entry.
    corr = leo_detectability(struct('mode', 'corrections'));
    isN  = corr.Kind == "norad" & corr.Key ~= "25544";
    tItems = [{'ISS only', 'All LEO', 'All corrected objects'}, cellstr(corr.Label(isN)).', ...
              cellstr(corr.Label(corr.Kind == "name")).', {'NORAD IDs', 'Name search'}];
    tData  = [{'iss', 'all', 'allcorr'}, cellstr("id:" + corr.Key(isN)).', ...
              cellstr("rule:" + corr.Key(corr.Kind == "name")).', {'ids', 'name'}];
    tgt = uidropdown(ctl, 'Items', tItems, 'ItemsData', tData, 'Value', 'iss', ...
                     'Tooltip', 'Corrected objects use a hand-set RCS (see the RCS_source column)', ...
                     'ValueChangedFcn', @(~,~) updateIds());
    place(tgt, r);
    r = r + 1;  lab(ctl, r, 'NORAD IDs');
    ids = uieditfield(ctl, 'text', 'Value', '25544', 'Tooltip', 'Comma-separated, e.g. 25544, 48274', ...
                      'Enable', 'off');
    place(ids, r);
    r = r + 1;  lab(ctl, r, 'Name contains');
    nameF = uieditfield(ctl, 'text', 'Value', '', 'Enable', 'off', 'Placeholder', 'e.g. tiangong, hubble', ...
                        'Tooltip', ['Comma-separated; matches anywhere in the name, case-insensitive ' ...
                                    '(regular expressions allowed, e.g. ^STARLINK-1)']);
    place(nameF, r);
    r = r + 1;  lab(ctl, r, 'Min elevation (deg)');
    minEl = uispinner(ctl, 'Limits', [0 89], 'Value', 20, 'Step', 5);
    place(minEl, r);
    r = r + 1;  lab(ctl, r, 'Threshold (sigma)');
    ksig = uispinner(ctl, 'Limits', [1 10], 'Value', 3, 'Step', 1);
    place(ksig, r);
    r = r + 1;  lab(ctl, r, 'Track window');
    trk = uidropdown(ctl, 'Items', {'Auto (best 1-120 s)', '1 s (snapshot)', '10 s', '30 s', '60 s', '90 s', '120 s'}, ...
                     'ItemsData', {0, 1, 10, 30, 60, 90, 120}, ...
                     'Tooltip', 'Integration along the pass. Auto picks the best window per object.');
    place(trk, r);
    r = r + 1;  lab(ctl, r, 'Pass search (days)');
    sdays = uispinner(ctl, 'Limits', [1 14], 'Value', 7, 'Step', 1);
    place(sdays, r);

    r = r + 1;  head(ctl, r, 'Orbit data');
    r = r + 1;  lab(ctl, r, 'Source');
    src = uidropdown(ctl, 'Items', {'CelesTrak (cached)', 'TLE file'}, 'ItemsData', {'celestrak', 'file'}, ...
                     'ValueChangedFcn', @(~,~) updateSrc());
    place(src, r);
    r = r + 1;  lab(ctl, r, 'TLE file');
    fileFld = uieditfield(ctl, 'text', 'Value', 'leo.tle', 'Enable', 'off');
    place(fileFld, r);
    r = r + 1;
    browse = uibutton(ctl, 'Text', 'Browse...', 'Enable', 'off', 'ButtonPushedFcn', @(~,~) onBrowse());
    browse.Layout.Row = r;  browse.Layout.Column = 2;

    r = r + 1;
    btnPass = uibutton(ctl, 'Text', 'Find passes', 'ButtonPushedFcn', @(~,~) onPasses(), ...
                       'Tooltip', 'List passes of the chosen objects over the search days (over 50 objects, e.g. All LEO or a constellation: detectable passes only)');
    btnPass.Layout.Row = r;  btnPass.Layout.Column = 1;
    btnRun = uibutton(ctl, 'Text', 'Run', 'FontWeight', 'bold', 'ButtonPushedFcn', @(~,~) onRun());
    btnRun.Layout.Row = r;  btnRun.Layout.Column = 2;

    logBox = uitextarea(ctl, 'Editable', 'off', 'FontName', 'Consolas', 'FontSize', 10);
    logBox.Layout.Row = 21;  logBox.Layout.Column = [1 2];
    logBox.Value = {'Choose a window and press Run, or Find passes.'};
    note = uilabel(ctl, 'Text', 'Times are Brisbane local (UTC+10).', 'FontAngle', 'italic');
    note.Layout.Row = 22;  note.Layout.Column = [1 2];

    % ---------------- results ----------------
    tabs = uitabgroup(main);
    tabRes  = uitab(tabs, 'Title', 'Candidates');
    tabPlot = uitab(tabs, 'Title', 'Plots');
    tabPass = uitab(tabs, 'Title', 'Passes');
    tabMap  = uitab(tabs, 'Title', 'Site map');
    tabHw   = uitab(tabs, 'Title', 'Hardware');
    tabAs   = uitab(tabs, 'Title', 'Model');

    gRes = uigridlayout(tabRes, [2 1]);  gRes.RowHeight = {22, '1x'};
    resLbl = uilabel(gRes, 'Text', 'No results yet.');
    resTbl = uitable(gRes);

    gPlot = uigridlayout(tabPlot, [3 2]);
    gPlot.RowHeight = {40, '1x', '1x'};
    plotLbl = uilabel(gPlot, 'Text', 'Press Run to plot.', 'WordWrap', 'on');
    plotLbl.Layout.Row = 1;  plotLbl.Layout.Column = [1 2];
    ax = gobjects(1, 4);
    for i = 1:4
        ax(i) = uiaxes(gPlot);
        ax(i).Layout.Row = 2 + (i > 2);  ax(i).Layout.Column = 1 + mod(i-1, 2);
    end

    lastOut = [];

    % ---------------- site map ----------------
    gMap = uigridlayout(tabMap, [3 2]);
    gMap.RowHeight = {30, 40, '1x'};  gMap.ColumnWidth = {'1.25x', '1x'};
    gMc = uigridlayout(gMap, [1 12]);  gMc.Layout.Row = 1;  gMc.Layout.Column = [1 2];
    gMc.ColumnWidth = {28, 90, 30, 90, 70, 110, 60, 120, 110, 100, 120, '1x'};  gMc.Padding = [0 0 0 0];
    uilabel(gMc, 'Text', 'Lat');
    mapLat = uieditfield(gMc, 'numeric', 'Value', -27.39602, 'ValueDisplayFormat', '%.5f', 'Limits', [-90 90], ...
                         'ValueChangedFcn', @(~,~) onLatLon());
    uilabel(gMc, 'Text', 'Lon');
    mapLon = uieditfield(gMc, 'numeric', 'Value', 151.93897, 'ValueDisplayFormat', '%.5f', 'Limits', [-180 180], ...
                         'ValueChangedFcn', @(~,~) onLatLon());
    uilabel(gMc, 'Text', 'Noise env.');
    mapEnv = uidropdown(gMc, 'Items', {'Quiet rural', 'Rural', 'Residential', 'Business'}, ...
                        'ItemsData', {'quietrural', 'rural', 'residential', 'business'}, 'Value', 'rural', ...
                        'Tooltip', 'Man-made radio noise at the site (ITU-R P.372)');
    uilabel(gMc, 'Text', 'Basemap');
    mapBase = uidropdown(gMc, 'Items', {'grayterrain', 'colorterrain', 'grayland', 'darkwater', 'streets', 'satellite', 'topographic'}, ...
                         'Value', 'grayterrain', 'ValueChangedFcn', @(~,~) setBasemap(), ...
                         'Tooltip', 'streets, satellite and topographic need internet access');
    uibutton(gMc, 'Text', 'Analyse site', 'FontWeight', 'bold', 'ButtonPushedFcn', @(~,~) onAnalyseSite(), ...
             'Tooltip', 'Full calculation at this location (terrain, patterns, polarisation, swamping) for the current Setup');
    uibutton(gMc, 'Text', 'Use for Run', 'ButtonPushedFcn', @(~,~) useMapSite(), ...
             'Tooltip', 'Set Site = Custom (map) so Run and Find passes use this location');
    bestGo = uidropdown(gMc, 'Items', {'Go to best site', 'Best FM site', 'Best DAB+ site', 'Best DTV site'}, ...
                        'ItemsData', {'', 'FM', 'DAB+', 'DTV'}, 'Value', '', 'ValueChangedFcn', @(~,~) goBestSite(), ...
                        'Tooltip', 'Move the capture site to the predicted best site for a band (stars on the map)');
    mapLbl = uilabel(gMap, 'Text', ['Click the map to choose a capture location, then press Analyse site. ' ...
                                    'Triangles = transmitters (size = power).'], 'WordWrap', 'on');
    mapLbl.Layout.Row = 2;  mapLbl.Layout.Column = [1 2];
    gx = geoaxes(gMap);  gx.Layout.Row = 3;  gx.Layout.Column = 1;
    mapTbl = uitable(gMap);  mapTbl.Layout.Row = 3;  mapTbl.Layout.Column = 2;
    try, geobasemap(gx, 'grayterrain'); catch, end
    geolimits(gx, [-28.7 -26.1], [151.0 154.0]);
    mapTx = [];  mapOut = [];  bestOut = [];

    gPass = uigridlayout(tabPass, [2 1]);  gPass.RowHeight = {22, '1x'};
    passLbl = uilabel(gPass, 'Text', 'Press Find passes. Click a pass to load its window, then press Run.');
    passTbl = uitable(gPass, 'CellSelectionCallback', @onPassSelect);

    % ---------------- hardware: values from your datasheets ----------------
    hwFile = fullfile(fileparts(mfilename('fullpath')), 'leo_hardware.mat');
    gHw = uigridlayout(tabHw, [26 3]);  gHw.Scrollable = 'on';
    gHw.ColumnWidth = {280, 170, '1x'};
    gHw.RowHeight = repmat({24}, 1, 26);
    hr = 1;
    hwNote = uilabel(gHw, 'WordWrap', 'on', 'FontAngle', 'italic', 'Text', ['Your receiving hardware, from the ' ...
        'SDR, amplifier and cable datasheets. Every run uses these values. The antenna is an Antenna Toolbox ' ...
        'model (real geometry, 3D gain for H and V polarisation, mismatch away from the design frequency, feed matched there by a balun) pointing straight up.']);
    hwNote.Layout.Row = [hr hr+1];  hwNote.Layout.Column = [1 3];
    hr = hr + 2;
    bSave = uibutton(gHw, 'Text', 'Save as my default', 'ButtonPushedFcn', @(~,~) saveHardware());
    bSave.Layout.Row = hr;  bSave.Layout.Column = 1;
    bReset = uibutton(gHw, 'Text', 'Reset to default values', 'ButtonPushedFcn', @(~,~) setHardware(defaultHW()));
    bReset.Layout.Row = hr;  bReset.Layout.Column = 2;
    gPre = uigridlayout(gHw, [1 2]);  gPre.Layout.Row = hr;  gPre.Layout.Column = 3;
    gPre.ColumnWidth = {95, 260};  gPre.Padding = [0 0 0 0];
    uilabel(gPre, 'Text', 'Load antenna:', 'HorizontalAlignment', 'right');
    hw.preset = uidropdown(gPre, 'Items', {'(choose an antenna)', 'Digitek 01EFM3 FM Yagi (3 el)', 'Digitek 01BUWX16L UHF Yagi', ...
                                     'Digitek 01EDAB DAB+ folded dipole'}, ...
                           'ItemsData', {'', 'efm3', 'buwx16l', 'edab'}, 'Value', '', ...
                           'ValueChangedFcn', @(~,~) loadAntenna(), ...
                           'Tooltip', 'Fills in the antenna fields; SDR, amplifier and cable are unchanged');

    hr = hr + 1;  hhead(gHw, hr, 'Antenna');
    hw.name = hfield(gHw, hr+1, 'Name', 'text', '', '');
    amLbl = uilabel(gHw, 'Text', 'Antenna model (Antenna Toolbox)');  amLbl.Layout.Row = hr+2;  amLbl.Layout.Column = 1;
    hw.antModel = uidropdown(gHw, 'Items', {'Dipole', 'Folded dipole', 'Yagi-Uda', 'Circular loop'}, ...
                             'ItemsData', {'dipole', 'dipoleFolded', 'yagi', 'loop'}, 'Value', 'dipole', ...
                             'ValueChangedFcn', @(~,~) antModelChanged(true), ...
                             'Tooltip', ['Antenna Toolbox builds the antenna at the design frequency and computes its ' ...
                                         'real 3D gain for H and V polarisation, including mismatch away from the design frequency (feed matched there).']);
    hw.antModel.Layout.Row = hr+2;  hw.antModel.Layout.Column = 2;
    amn = uilabel(gHw, 'WordWrap', 'on', 'FontColor', [0.4 0.4 0.4], 'Text', ...
        'Transmitters within 0.7-1.4 x the design frequency are considered; the mismatch sets the usable band.');
    amn.Layout.Row = hr+2;  amn.Layout.Column = 3;
    hw.designMHz = hfield(gHw, hr+3, 'Design frequency', 'numeric', 0, 'MHz');
    hw.nEl = hfield(gHw, hr+4, 'Number of elements (Yagi-Uda)', 'numeric', 3, '');
    pLbl = uilabel(gHw, 'Text', 'Mounting (polarisation)');  pLbl.Layout.Row = hr+5;  pLbl.Layout.Column = 1;
    hw.rxPol = uidropdown(gHw, 'Items', {'Horizontal', 'Vertical'}, 'ItemsData', {'H', 'V'}, 'Value', 'H');
    hw.rxPol.Layout.Row = hr+5;  hw.rxPol.Layout.Column = 2;
    hw.elemAz = hfield(gHw, hr+6, 'Horizontal elements lie along (from north)', 'numeric', 90, 'deg');
    hw.elemAz.Limits = [0 360];
    hw.elemAz.Tooltip = ['Direction the elements of a flat-mounted antenna run along (90 = east-west). A dipole ' ...
                         'is blind along its length, so this sets which transmitters fall in its null.'];

    hr = hr + 7;  hhead(gHw, hr, 'Receiver (SDR)');
    hw.sdr   = hfield(gHw, hr+1, 'Name', 'text', '', '');
    hw.NF    = hfield(gHw, hr+2, 'Noise figure', 'numeric', 0, 'dB');
    hw.DR    = hfield(gHw, hr+3, 'Blocking dynamic range', 'numeric', 0, 'dB');
    hw.maxIn = hfield(gHw, hr+4, 'Maximum input', 'numeric', 0, 'dBm');
    hw.IRR   = hfield(gHw, hr+5, 'IQ image rejection', 'numeric', 0, 'dB');
    hw.sdrBW = hfield(gHw, hr+6, 'Capture bandwidth', 'numeric', 0, 'MHz');
    hw.sdrBW.Tooltip = ['Every station inside this bandwidth reaches the ADC: their total power, less the ' ...
                        'blocking dynamic range, sets the noise floor in each channel (swamping).'];

    hr = hr + 7;  hhead(gHw, hr, 'Amplifier, filter and cable');
    lnaLbl = uilabel(gHw, 'Text', 'Masthead amplifier');  lnaLbl.Layout.Row = hr+1;  lnaLbl.Layout.Column = 1;
    hw.lnaOn = uicheckbox(gHw, 'Text', 'fitted', 'Value', false);  hw.lnaOn.Layout.Row = hr+1;  hw.lnaOn.Layout.Column = 2;
    hw.lnaNF = hfield(gHw, hr+2, 'Amplifier noise figure', 'numeric', 0, 'dB');
    hw.lnaG  = hfield(gHw, hr+3, 'Amplifier gain', 'numeric', 0, 'dB');
    hw.filt  = hfield(gHw, hr+4, 'Filter rejection of other stations (0 = none)', 'numeric', 0, 'dB');
    hw.filt.Tooltip = 'e.g. a band-pass or notch filter in front of the SDR: reduces swamping by the other stations';
    hw.cable = hfield(gHw, hr+5, 'Cable length', 'numeric', 0, 'm');
    hw.c100  = hfield(gHw, hr+6, 'Cable loss at 100 MHz', 'numeric', 0, 'dB/100 m');
    hw.c600  = hfield(gHw, hr+7, 'Cable loss at 600 MHz', 'numeric', 0, 'dB/100 m');

    % your saved values, else the defaults
    hwStart = defaultHW();
    if isfile(hwFile)
        try
            S = load(hwFile, 'hwSaved');
            if isfield(S.hwSaved, 'antModel') && ~strcmp(S.hwSaved.antModel, 'datasheet')   % ignore older files
                hwStart = S.hwSaved;
            end
        catch
        end
    end
    setHardware(hwStart);

    % ---------------- model: processing, options and assumptions ----------------
    gAs = uigridlayout(tabAs, [3 1]);  gAs.RowHeight = {412, 30, '1x'};
    gMo = uigridlayout(gAs, [15 3]);  gMo.ColumnWidth = {280, 300, '1x'};  gMo.RowHeight = repmat({24}, 1, 15);
    gMo.Padding = [0 0 0 0];
    mr = 1;  hhead(gMo, mr, 'Processing');
    rsLbl = uilabel(gMo, 'Text', 'Separate reference antenna');  rsLbl.Layout.Row = mr+1;  rsLbl.Layout.Column = 1;
    hw.refSep = uicheckbox(gMo, 'Text', 'second SDR on its own antenna aimed at the transmitter', 'Value', false);
    hw.refSep.Layout.Row = mr+1;  hw.refSep.Layout.Column = [2 3];
    caLbl = uilabel(gMo, 'Text', 'Direct-path cancellation');  caLbl.Layout.Row = mr+2;  caLbl.Layout.Column = 1;
    hw.cancel = uidropdown(gMo, 'Items', {'Fixed (cancel_dB, Assumptions sheet)', 'ECA-B (modelled per channel)'}, ...
                           'ItemsData', {'fixed', 'eca'}, 'Value', 'fixed', ...
                           'Tooltip', ['ECA-B: least-squares cancellation in batches. Per channel it is limited by the ' ...
                                       'reference S/N (unless DAB+/TV is decoded) and by eca_ceiling_dB. Shown in the Site ' ...
                                       'map table (Cancel_dB).']);
    hw.cancel.Layout.Row = mr+2;  hw.cancel.Layout.Column = 2;
    mcLbl = uilabel(gMo, 'Text', 'Motion correction');  mcLbl.Layout.Row = mr+3;  mcLbl.Layout.Column = 1;
    hw.motion = uicheckbox(gMo, 'Text', ['orbit-based (TLE): coherent over the whole 1 s frame ' ...
                           '(about +5 dB FM, +8 dB DAB+, +11 dB DTV; assumes the orbit is exact)'], 'Value', false, ...
                           'Tooltip', ['Off: coherent time from the physics of each pass (about 0.1 s FM, 26 ms DAB+, ' ...
                                       '6 ms DTV). On: range migration and Doppler change removed using the orbit. ' ...
                                       'Only possible for catalogued objects.']);
    hw.motion.Layout.Row = mr+3;  hw.motion.Layout.Column = [2 3];
    hw.motion.ValueChangedFcn = @(~,~) set(hw.blind, 'Enable', ~hw.motion.Value);
    blLbl = uilabel(gMo, 'Text', 'Blind search (untracked objects)');  blLbl.Layout.Row = mr+4;  blLbl.Layout.Column = 1;
    hw.blind = uicheckbox(gMo, 'Text', ['keystone + Doppler-rate trials: coherent 1 s without the orbit, ' ...
                          'less the false-alarm cost of the trials (about 1.5-2 dB)'], 'Value', false, ...
                          'Tooltip', ['For objects with no TLE. Range migration is removed by the keystone transform; the ' ...
                                      'Doppler change is found by testing every Doppler rate a LEO object can have. More ' ...
                                      'trials raise the detection threshold, which is subtracted. Ignored if motion ' ...
                                      'correction is on.']);
    hw.blind.Layout.Row = mr+4;  hw.blind.Layout.Column = [2 3];
    hw.nChan = hfield(gMo, mr+5, 'Channels combined (best N in the antenna band)', 'numeric', 1, '');
    hw.nChan.Limits = [1 20];  hw.nChan.RoundFractionalValues = 'on';
    hw.nChan.Tooltip = ['Each station lights the same object: maps from N channels in one capture are combined ' ...
                        '(S/N x about sqrt(N) for similar channels). Software only.'];
    hw.arrayN = hfield(gMo, mr+6, 'Antennas in array (beamformed)', 'numeric', 1, '');
    hw.arrayN.Limits = [1 64];  hw.arrayN.RoundFractionalValues = 'on';
    hw.arrayN.Tooltip = ['N copies of the Hardware-tab antenna, each on its own SDR channel sharing one clock, ' ...
                         'beamformed towards the object: S/N x N, same field of view (beams formed in software). ' ...
                         'Mutual coupling and calibration errors ignored.'];
    mr = mr + 7;  hhead(gMo, mr, 'Transmitters and objects');
    txLbl = uilabel(gMo, 'Text', 'Transmitters');  txLbl.Layout.Row = mr+1;  txLbl.Layout.Column = 1;
    hw.txSet = uidropdown(gMo, 'Items', {'All within 150 km (Transmitters sheet)', 'Original four sites (Original4 sheet)'}, ...
                          'ItemsData', {'seq', 'original'}, 'Value', 'seq');
    hw.txSet.Layout.Row = mr+1;  hw.txSet.Layout.Column = 2;
    hw.exclude = hfield(gMo, mr+2, 'Exclude transmitters (callsigns or areas)', 'text', '', '');
    vLbl = uilabel(gMo, 'Text', 'Transmitter power towards objects');  vLbl.Layout.Row = mr+3;  vLbl.Layout.Column = 1;
    hw.txVert = uidropdown(gMo, 'Items', {'Paper (Gtx = 0.5, Tingay 2013)', 'LOFAR measured (-16 dB, Poland, Jedrzejewski 2025)'}, ...
                           'ItemsData', {'paper', 'measured'}, 'Value', 'paper');
    hw.txVert.Layout.Row = mr+3;  hw.txVert.Layout.Column = 2;
    hw.daAtt = hfield(gMo, mr+4, 'Directional transmitters: loss towards you', 'numeric', 0, 'dB');
    hw.starlink = hfield(gMo, mr+5, 'Starlink RCS if not in SATCAT', 'numeric', 50, 'm^2');
    hw.patFile = hfield(gMo, mr+6, 'Azimuth pattern CSV (optional)', 'text', '', '');
    hw.patFile.Placeholder = 'blank = Tx_patterns sheet';
    gAsB = uigridlayout(gAs, [1 2]);  gAsB.ColumnWidth = {160, '1x'};  gAsB.Padding = [0 0 0 0];
    uibutton(gAsB, 'Text', 'Open data workbook', 'ButtonPushedFcn', @(~,~) onOpenInputs(), ...
             'Tooltip', 'leo_inputs.xlsx: transmitters, RCS corrections, patterns and the model values');

    drawMap();                                       % transmitters + Cooby Creek on the map
    loadBestSite();                                  % fixed best-site prediction (computed once, then saved)

    % ---------------- callbacks ----------------
    function loadAntenna()
        a = antennaPreset(hw.preset.Value);
        if isempty(a), return; end
        hw.name.Value = a.name;  hw.rxPol.Value = a.pol;
        hw.antModel.Value = a.antModel;  hw.designMHz.Value = a.designMHz;  hw.nEl.Value = a.nElements;
        antModelChanged(false);
        hwName.Text = string(a.name) + " + " + string(hw.sdr.Value);
        say(sprintf('Loaded the %s into the Hardware tab (%s).', a.name, a.note));
        hw.preset.Value = '';
    end

    function antModelChanged(byUser)
    % Number of elements only applies to a Yagi-Uda. If you change the model of a
    % named preset by hand, the name no longer describes the antenna: rename it.
        isY = strcmp(hw.antModel.Value, 'yagi');
        hw.nEl.Enable = matlab.lang.OnOffSwitchState(isY);
        if ~isY, hw.nEl.Value = 1; elseif hw.nEl.Value < 3, hw.nEl.Value = 3; end
        if byUser
            presets = {antennaPreset('efm3'), antennaPreset('buwx16l'), antennaPreset('edab'), defaultHW()};
            if any(cellfun(@(a) strcmp(string(a.name), string(hw.name.Value)), presets))
                hw.name.Value = sprintf('%s at %g MHz', hw.antModel.Items{strcmp(hw.antModel.ItemsData, ...
                                        hw.antModel.Value)}, hw.designMHz.Value);
            end
            hwName.Text = string(hw.name.Value) + " + " + string(hw.sdr.Value);
        end
    end

    function goHardware()
        tabs.SelectedTab = tabHw;
    end

    function c = readHardware()
        c = struct('name', string(hw.name.Value), 'pol', hw.rxPol.Value, 'elemAz', hw.elemAz.Value, 'sdrName', string(hw.sdr.Value), 'NF', hw.NF.Value, ...
                   'DR', hw.DR.Value, 'maxIn', hw.maxIn.Value, 'IRR', hw.IRR.Value, 'sdrBW', hw.sdrBW.Value, ...
                   'lnaOn', hw.lnaOn.Value, 'lnaNF', hw.lnaNF.Value, 'lnaGain', hw.lnaG.Value, 'filt', hw.filt.Value, ...
                   'cableLen', hw.cable.Value, 'cable100', hw.c100.Value, 'cable600', hw.c600.Value, ...
                   'antModel', hw.antModel.Value, 'designMHz', hw.designMHz.Value, 'nElements', hw.nEl.Value);
        if c.designMHz <= 0
            error('Hardware: set the design frequency of the antenna.');
        end
    end

    function setHardware(c)
        d = defaultHW();  f = fieldnames(d);
        for k = 1:numel(f), if ~isfield(c, f{k}), c.(f{k}) = d.(f{k}); end, end
        hw.name.Value = c.name;  hw.rxPol.Value = c.pol;  hw.elemAz.Value = c.elemAz;
        hw.sdr.Value = c.sdrName;  hw.NF.Value = c.NF;  hw.DR.Value = c.DR;  hw.maxIn.Value = c.maxIn;
        hw.IRR.Value = c.IRR;  hw.sdrBW.Value = c.sdrBW;
        hw.lnaOn.Value = c.lnaOn;  hw.lnaNF.Value = c.lnaNF;  hw.lnaG.Value = c.lnaGain;  hw.filt.Value = c.filt;
        hw.cable.Value = c.cableLen;  hw.c100.Value = c.cable100;  hw.c600.Value = c.cable600;
        hw.antModel.Value = c.antModel;  hw.designMHz.Value = c.designMHz;  hw.nEl.Value = c.nElements;
        antModelChanged(false);
        hwName.Text = string(c.name) + " + " + string(c.sdrName);
    end

    function saveHardware()
        try
            hwSaved = readHardware();  save(hwFile, 'hwSaved');
            hwName.Text = hwSaved.name + " + " + hwSaved.sdrName;
            say(sprintf('Hardware saved as your default (%s).', hwFile));
        catch err
            uialert(fig, err.message, 'Could not save');
        end
    end

    function onSiteChange()
        switch site.Value
            case 'Cooby Creek', mapLat.Value = -27.39602;  mapLon.Value = 151.93897;  mapEnv.Value = 'rural';
            case 'UQ St Lucia', mapLat.Value = -27.49753;  mapLon.Value = 153.01328;  mapEnv.Value = 'business';
            otherwise, tabs.SelectedTab = tabMap;
        end
        mapOut = [];  drawMap();
    end

    function onLatLon()
        site.Value = 'Custom';  mapOut = [];  drawMap();
    end

    function useMapSite()
        site.Value = 'Custom';
        say(sprintf('Site set to the map location %.5f, %.5f (%s).', mapLat.Value, mapLon.Value, mapEnv.Value));
    end

    function setBasemap()
        try
            geobasemap(gx, mapBase.Value);
        catch err
            uialert(fig, ['Basemap not available: ' err.message], 'Basemap');
            mapBase.Value = 'grayterrain';  geobasemap(gx, 'grayterrain');
        end
    end

    function onMapClick(~, ev)
        cp = [];
        try, cp = ev.IntersectionPoint; catch, end    % [lat lon (alt)] on geographic axes
        if isempty(cp), try, cp = gx.CurrentPoint; catch, end, end
        if isempty(cp) || any(~isfinite(cp(1,1:2))), return; end
        mapLat.Value = round(cp(1,1), 5);  mapLon.Value = round(cp(1,2), 5);
        site.Value = 'Custom';  mapOut = [];  drawMap();
        mapLbl.Text = sprintf('Site moved to %.5f, %.5f. Press Analyse site for the interference picture here.', ...
                              mapLat.Value, mapLon.Value);
    end

    function loadBestSite()
    % The best capture sites (FM, DAB+, DTV) are computed once and saved in
    % best_site.mat next to leo_detectability.m; every later start loads them, so
    % the stars are in the same place every time. Delete best_site.mat to search
    % again (e.g. after changing the SDR, amplifier or cable).
        dlg = [];
        f = fullfile(fileparts(which('leo_detectability')), 'best_site.mat');
        need = true;
        if isfile(f)
            try, S = load(f, 'out'); need = ~isfield(S.out, 'version') || S.out.version < 3; catch, end
        end
        if need
            dlg = uiprogressdlg(fig, 'Title', 'Best-site prediction', 'Indeterminate', 'on', 'Message', ...
                ['Searching the area covered by the transmitter data for the best FM, DAB+ and DTV capture ' ...
                 'sites. This runs once (it can take a while) and is saved for every later start.']);
        end
        busy(true);  cleanup = onCleanup(@() busy(false));
        try
            cfg = readControls();
            cfg.mode = 'bestsite';  cfg.site = 'Cooby Creek';
            bestOut = leo_detectability(cfg);
            drawMap();
        catch err
            say(['Best-site prediction failed: ' err.message]);
        end
        if ~isempty(dlg), close(dlg); end
    end

    function goBestSite()
        bnd = bestGo.Value;  bestGo.Value = '';
        if isempty(bnd), return; end
        if isempty(bestOut), uialert(fig, 'The best-site prediction is not available.', 'Best site'); return; end
        k = find(strcmp({bestOut.bands.band}, bnd), 1);
        if isempty(k), uialert(fig, sprintf('No best %s site (no %s channel gives a signal).', bnd, bnd), 'Best site'); return; end
        B = bestOut.bands(k);
        mapLat.Value = B.bestLat;  mapLon.Value = B.bestLon;  mapEnv.Value = bestOut.env;
        site.Value = 'Custom';  mapOut = [];  drawMap();
        mapLbl.Text = sprintf(['Predicted best %s site %.4f, %.4f: %.1f dB S/N per 1 s for a 1 m^2 object 500 km ' ...
            'overhead via %s, with %s (%s noise; computed %s). Access and land use are not considered. ' ...
            'Load that antenna in the Hardware tab, then press Analyse site.'], B.band, B.bestLat, B.bestLon, ...
            B.score_dB, B.channel, B.antenna, bestOut.env, char(bestOut.computed, 'dd-MMM-yyyy'));
        if B.atEdge
            mapLbl.Text = [mapLbl.Text ' It lies on the edge of the area covered by the transmitter data, ' ...
                           'so it mainly reflects distance from the strong transmitters.'];
        end
    end

    function onAnalyseSite()
        busy(true);  cleanup = onCleanup(@() busy(false));
        try
            cfg = readControls();
            cfg.mode = 'site';  cfg.site = 'Custom';
            say(sprintf('--- Site analysis: %.5f, %.5f (%s) ---', mapLat.Value, mapLon.Value, mapEnv.Value));
            mapOut = leo_detectability(cfg);
            T = mapOut.table;
            show = {'Rank','Channel','DirectAboveNoise_dB','TerrainLoss_dB','Dist_km','ERP_kW','MHz','SDRin_dBm','Swamping_dB','Cancel_dB'};
            D = T(:, show);
            D.TerrainLoss_dB(~T.TerrainComputed) = NaN;       % skipped by the screen: free-space values
            D.Properties.VariableNames{'TerrainLoss_dB'} = 'TerrainLoss_dB (blank = not computed)';
            mapTbl.Data = D;
            mapTbl.ColumnWidth = {45, 190, 90, 110, 70, 65, 70, 75, 85, 75};
            dn = T.DirectAboveNoise_dB;  dn(~T.TerrainComputed) = -Inf;
            [dmax, im] = max(dn);  ff = '';
            if ~isfinite(dmax), [dmax, im] = max(T.DirectAboveNoise_dB);  ff = ', free space'; end
            nOver = sum(T.SDRin_dBm > 10);
            mapLbl.Text = sprintf(['%s. Best channels: %s. Strongest direct signal %.0f dB above noise (%s). ' ...
                '%sLines: direct signal above noise per mast (thick = channels the model would use). ' ...
                'Channels screened out keep free-space values (shown blank in the terrain column).'], ...
                mapOut.rcv.name, strjoin(mapOut.chosen(1:min(3,end)), ', '), dmax, T.Channel(im) + ff, ...
                ternary(nOver > 0, sprintf('%d channel(s) would overload the SDR. ', nOver), ''));
            drawMap();
        catch err
            uialert(fig, err.message, 'Site analysis failed');
            say(['Error: ' err.message]);
        end
    end

    function drawMap()
        cla(gx);  hold(gx, 'on');
        lat0 = mapLat.Value;  lon0 = mapLon.Value;
        if ~isempty(mapOut)                           % free-space total direct power
            G = mapOut.grid;
            hg = geoscatter(gx, G.lat(:), G.lon(:), 48, G.PdBm(:), 's', 'filled', 'MarkerFaceAlpha', 0.3, ...
                            'MarkerEdgeColor', 'none', 'DisplayName', 'Total direct power (free space)');
            hg.PickableParts = 'none';
            colormap(gx, turbo);  cb = colorbar(gx);
            cb.Label.String = 'Total direct-path power at the antenna, free space (dBm)';
            v = sort(G.PdBm(:));  lims = [v(max(1, round(0.02*end))), v(max(2, round(0.995*end)))];
            try, gx.CLim = lims; catch, try, caxis(gx, lims); catch, end, end
            % one line per mast, coloured by its strongest direct signal above noise
            T = mapOut.table;
            key = compose('%.4f,%.4f', T.Lat, T.Lon);  [u, ~, j] = unique(key, 'stable');
            cls = {[-Inf 20], [20 40], [40 60], [60 Inf]};
            col = {[0.2 0.6 0.2], [0.95 0.8 0.1], [0.95 0.5 0.1], [0.8 0.1 0.1]};
            names = {'Direct signal < 20 dB above noise', '20-40 dB', '40-60 dB', '> 60 dB'};
            for c = 1:4                                  % legend entries in a fixed order
                geoplot(gx, NaN, NaN, '-', 'Color', col{c}, 'LineWidth', 2, 'DisplayName', names{c});
            end
            for i = 1:numel(u)
                k = find(j == i);  [dn, b] = max(T.DirectAboveNoise_dB(k));
                c = find(cellfun(@(r) dn >= r(1) && dn < r(2), cls), 1);
                used = any(T.Rank(k) <= 6);
                h = geoplot(gx, [lat0 T.Lat(k(b))], [lon0 T.Lon(k(b))], '-', 'Color', col{c}, ...
                            'LineWidth', 1 + 2.5*used, 'DisplayName', names{c});
                h.PickableParts = 'none';  h.HandleVisibility = 'off';
                if used
                    ht = text(gx, T.Lat(k(b)), T.Lon(k(b)), "  " + T.Channel(k(b)), 'FontSize', 8, 'FontWeight', 'bold');
                    ht.PickableParts = 'none';
                end
            end
        end
        if isempty(mapTx)
            try
                mapTx = leo_detectability(struct('mode', 'txlist', 'txSet', hw.txSet.Value));
            catch
                mapTx = table();
            end
        end
        if ~isempty(mapTx)
            ht = geoscatter(gx, mapTx.Lat, mapTx.Lon, 12 + 14*log10(1 + mapTx.MaxERP_kW), 'k^', 'filled', ...
                            'MarkerFaceColor', [0.25 0.25 0.25], 'DisplayName', 'Transmitter (size = power)');
            ht.PickableParts = 'none';
            big = find(mapTx.MaxERP_kW >= 20);
            for i = big'
                tt = text(gx, mapTx.Lat(i), mapTx.Lon(i), "  " + mapTx.Area(i), 'FontSize', 7, 'Color', [0.3 0.3 0.3]);
                tt.PickableParts = 'none';
            end
        end
        if ~isempty(bestOut)                          % fixed best-site predictions, one per band
            bc = struct('FM', [1 0.8 0.1], 'DAB', [0.2 0.75 0.95], 'DTV', [0.75 0.35 0.95]);
            for k = 1:numel(bestOut.bands)
                B = bestOut.bands(k);  col = bc.(strrep(B.band, '+', ''));
                hb = geoplot(gx, B.bestLat, B.bestLon, 'p', 'MarkerSize', 18, 'MarkerFaceColor', col, ...
                             'MarkerEdgeColor', 'k', 'LineWidth', 1, 'DisplayName', ['Best ' B.band ' site']);
                hb.PickableParts = 'none';
                tb = text(gx, B.bestLat, B.bestLon, sprintf('   Best %s (%.1f dB)', B.band, B.score_dB), ...
                          'FontSize', 8, 'FontWeight', 'bold');
                tb.PickableParts = 'none';
            end
        end
        hs = geoscatter(gx, lat0, lon0, 160, 'p', 'filled', 'MarkerFaceColor', [0.85 0.1 0.1], ...
                        'MarkerEdgeColor', 'w', 'DisplayName', 'Capture site');
        hs.PickableParts = 'none';
        legend(gx, 'Location', 'southoutside', 'NumColumns', 3, 'FontSize', 8);
        hold(gx, 'off');
        gx.ButtonDownFcn = @onMapClick;
    end

    function onOpenInputs()
        f = fullfile(fileparts(which('leo_detectability')), 'leo_inputs.xlsx');
        if ~isfile(f), uialert(fig, ['Not found: ' f], 'Data workbook'); return; end
        try
            if ispc, winopen(f); elseif ismac, system(['open "' f '"']); else, system(['xdg-open "' f '" &']); end
        catch err
            uialert(fig, err.message, 'Could not open the workbook');
        end
    end

    function updateIds()
        v = tgt.Value;
        ids.Enable = strcmp(v, 'ids');  nameF.Enable = strcmp(v, 'name');
        if strcmp(v, 'iss'), ids.Value = '25544';
        elseif startsWith(v, 'id:'), ids.Value = extractAfter(v, 3);
        elseif startsWith(v, 'rule:'), nameF.Value = extractAfter(v, 5);
        end
    end

    function updateSrc()
        isFile = strcmp(src.Value, 'file');
        fileFld.Enable = isFile;  browse.Enable = isFile;
    end

    function onBrowse()
        [f, p] = uigetfile({'*.tle;*.txt', 'TLE files'}, 'Choose a TLE file');
        figure(fig);
        if isequal(f, 0), return; end
        fileFld.Value = fullfile(p, f);
    end

    function cfg = readControls()
        tt = regexp(strtrim(tStart.Value), '^(\d{1,2}):(\d{2})$', 'tokens', 'once');
        if isempty(tt), error('Start time must be HH:mm, e.g. 19:00'); end
        d = dp.Value;
        cfg.start    = datetime(d.Year, d.Month, d.Day, str2double(tt{1}), str2double(tt{2}), 0, 'TimeZone', tz);
        cfg.duration = minutes(dur.Value);
        cfg.site     = site.Value;
        cfg.siteLat  = mapLat.Value;  cfg.siteLon = mapLon.Value;  cfg.siteEnv = mapEnv.Value;
        cfg.receiver = 'custom';
        cfg.custom   = readHardware();
        cfg.custom.refSeparate = hw.refSep.Value;
        cfg.minEl    = minEl.Value;
        cfg.kSigma   = ksig.Value;
        cfg.searchDays = sdays.Value;
        if trk.Value == 0, cfg.trackWindow = 'auto'; else, cfg.trackWindow = trk.Value; end
        cfg.txSet = hw.txSet.Value;
        cfg.sdrBW_MHz = cfg.custom.sdrBW;  cfg.filterRej_dB = cfg.custom.filt;
        cfg.txVertical = hw.txVert.Value;  cfg.daRxAtten_dB = hw.daAtt.Value;
        cfg.cancelMethod = hw.cancel.Value;
        cfg.txPatternFile = strtrim(hw.patFile.Value);
        cfg.rxPol = cfg.custom.pol;  cfg.motionComp = hw.motion.Value;
        cfg.antAz = mod(cfg.custom.elemAz - 90, 360);   % pointing azimuth; elements lie at +90 deg
        cfg.blindSearch = hw.blind.Value && ~hw.motion.Value;
        cfg.nChanSum = hw.nChan.Value;  cfg.arrayN = hw.arrayN.Value;
        ex = strtrim(strsplit(hw.exclude.Value, {',', ';'}));
        cfg.excludeTx = ex(~cellfun(@isempty, ex));
        cfg.rcsRules  = {'^STARLINK', hw.starlink.Value, 'assumed'};
        cfg.source   = src.Value;
        cfg.tleFile  = fileFld.Value;
        cfg.norad = {};  cfg.nameFilter = '';
        v = tgt.Value;
        if strcmp(v, 'iss'),         cfg.norad = {'25544'};
        elseif startsWith(v, 'id:'), cfg.norad = {extractAfter(v, 3)};
        elseif startsWith(v, 'rule:'), cfg.nameFilter = extractAfter(v, 5);
        elseif strcmp(v, 'allcorr')
            cfg.norad = cellstr(corr.Key(corr.Kind == "norad")).';
            cfg.nameFilter = char(strjoin(corr.Key(corr.Kind == "name"), ','));
        elseif strcmp(v, 'ids')
            cfg.norad = strtrim(strsplit(ids.Value, {',', ' ', ';'}));
            cfg.norad = cfg.norad(~cellfun(@isempty, cfg.norad));
            if isempty(cfg.norad), error('Enter at least one NORAD id.'); end
        elseif strcmp(v, 'name')
            cfg.nameFilter = strtrim(nameF.Value);
            if isempty(cfg.nameFilter), error('Enter part of an object name, e.g. tiangong.'); end
        end
        cfg.axes = ax;
        cfg.log  = @(varargin) say(sprintf(varargin{:}));
    end

    function onRun()
        busy(true);  cleanup = onCleanup(@() busy(false));
        try
            cfg = readControls();
            cfg.mode = 'rank';
            say(sprintf('--- Run: %s, %g min, %s, %s ---\n', char(cfg.start), dur.Value, cfg.site, hwName.Text));
            out = leo_detectability(cfg);
            if isempty(out.table) || height(out.table) == 0
                resTbl.Data = table();
                resLbl.Text = sprintf('No chosen objects reach %g deg elevation in this window.', cfg.minEl);
                for i = 1:4, cla(ax(i)); end
                plotLbl.Text = 'Nothing to plot.';
                lastOut = [];
            else
                resTbl.Data = out.table;
                lastOut = out;
                T1 = out.table(1,:);
                if T1.DetectTime_s > 0
                    dtxt = sprintf('detectable %s to %s (%g s of data, %g s integration window)', ...
                        char(string(T1.DetectFrom, 'HH:mm:ss')), char(string(T1.DetectTo, 'HH:mm:ss')), ...
                        T1.DetectTime_s, T1.TrackWindow_s);
                else
                    dtxt = 'not detectable in this window';
                end
                plotLbl.Text = sprintf('%s at %s. Top object: %s via %s, track S/N %.1f, %s. Up to %d objects plotted.', ...
                    out.rcv.name, out.rx.name, T1.Name, T1.BestChannel, T1.TrackSNR, dtxt, ...
                    min(height(out.table), 8));
                resLbl.Text = sprintf('%d objects visible, %d detectable at %g sigma (%s at %s). Ranked by track-integrated S/N.', ...
                    height(out.table), sum(out.table.Detectable), cfg.kSigma, out.rcv.name, out.rx.name);
                tabs.SelectedTab = tabRes;
            end
        catch err
            uialert(fig, err.message, 'Run failed');
            say(['Error: ' err.message]);
        end
    end

    function onPasses()
        busy(true);  cleanup = onCleanup(@() busy(false));
        try
            cfg = readControls();
            cfg.mode = 'passes';
            big = strcmp(tgt.Value, 'all') || strcmp(tgt.Value, 'allcorr') || startsWith(tgt.Value, 'rule:') || ...
                  (strcmp(tgt.Value, 'name') && any(strcmpi(strtrim(nameF.Value), {'starlink','^starlink'})));
            if strcmp(tgt.Value, 'all'), cfg.norad = {};  cfg.allPasses = true; end
            if big
                if cfg.searchDays > 2
                    ans_ = uiconfirm(fig, sprintf(['Searching many objects over %d days can take a long time ' ...
                        '(roughly several minutes per day searched). Search 1 day instead?'], cfg.searchDays), ...
                        'All-object pass search', 'Options', {'Search 1 day', sprintf('Search %d days', cfg.searchDays), 'Cancel'}, ...
                        'DefaultOption', 1, 'CancelOption', 3);
                    if strcmp(ans_, 'Cancel'), return; end
                    if strcmp(ans_, 'Search 1 day'), cfg.searchDays = 1; end
                end
            end
            say(sprintf('--- Passes from %s, %d days ---\n', char(cfg.start), cfg.searchDays));
            out = leo_detectability(cfg);
            passTbl.Data = out.passes;
            if height(out.passes) == 0 && isfield(cfg, 'allPasses') && cfg.allPasses
                passLbl.Text = sprintf('No objects predicted detectable in %d day(s) at %g sigma.', cfg.searchDays, cfg.kSigma);
            elseif height(out.passes) == 0
                passLbl.Text = sprintf('No passes above %g deg in %d days.', cfg.minEl, cfg.searchDays);
            else
                passLbl.Text = sprintf(['%d passes, %d predicted detectable at %g sigma. ' ...
                    'Click a pass to load its window, then press Run.'], height(out.passes), ...
                    sum(out.passes.Detectable), cfg.kSigma);
            end
            tabs.SelectedTab = tabPass;
        catch err
            uialert(fig, err.message, 'Pass search failed');
            say(['Error: ' err.message]);
        end
    end

    function onPassSelect(tblSrc, ev)
        if isempty(ev.Indices) || isempty(tblSrc.Data), return; end
        T = tblSrc.Data;  i = ev.Indices(1, 1);
        t0 = T.Rise(i) - minutes(2);  t1 = T.Set(i) + minutes(2);
        t0.TimeZone = tz;  t1.TimeZone = tz;
        dp.Value = datetime(t0.Year, t0.Month, t0.Day);
        tStart.Value = char(string(t0, 'HH:mm'));
        dur.Value = max(1, ceil(minutes(t1 - t0)) + 1);
        if ~strcmp(tgt.Value, 'iss')          % load just this object
            tgt.Value = 'ids';  updateIds();  ids.Value = char(T.NORAD(i));
        end
        say(sprintf('Loaded %s pass: %s to %s, max elevation %.0f deg. Press Run.', T.Name(i), ...
            char(string(t0, 'dd-MMM HH:mm')), char(string(t1, 'HH:mm')), T.MaxEl_deg(i)));
    end

    function say(msg)
        lines = splitlines(string(strip(msg, 'right', newline)));
        logBox.Value = [logBox.Value; cellstr(lines)];
        try, scroll(logBox, 'bottom'); catch, end
        drawnow limitrate;
    end

    function busy(on)
        if on
            btnRun.Enable = 'off';  btnPass.Enable = 'off';  fig.Pointer = 'watch';
        else
            btnRun.Enable = 'on';   btnPass.Enable = 'on';   fig.Pointer = 'arrow';
        end
        drawnow;
    end
end

% ---------------- layout helpers ----------------
function lab(g, r, txt)
    l = uilabel(g, 'Text', txt);
    l.Layout.Row = r;  l.Layout.Column = 1;
end

function head(g, r, txt)
    l = uilabel(g, 'Text', txt, 'FontWeight', 'bold');
    l.Layout.Row = r;  l.Layout.Column = [1 2];
end

function place(c, r)
    c.Layout.Row = r;  c.Layout.Column = 2;
end

function hhead(g, r, txt)
    l = uilabel(g, 'Text', txt, 'FontWeight', 'bold');
    l.Layout.Row = r;  l.Layout.Column = [1 2];
end

function f = hfield(g, r, txt, kind, val, unit)
    l = uilabel(g, 'Text', txt);  l.Layout.Row = r;  l.Layout.Column = 1;
    f = uieditfield(g, kind, 'Value', val);  f.Layout.Row = r;  f.Layout.Column = 2;
    if ~isempty(unit)
        u = uilabel(g, 'Text', unit);  u.Layout.Row = r;  u.Layout.Column = 3;
    end
end

function v = ternary(c, a, b)
    if c, v = a; else, v = b; end
end

function c = defaultHW()
% Default: half-wave dipole designed at 100 MHz (FM band), mounted horizontally,
% into the RigExpert Fobos.
    c = struct('name', "Default FM dipole", 'pol', 'H', 'elemAz', 90, ...
               'sdrName', "RigExpert Fobos", 'NF', 8, 'DR', 82, 'maxIn', 10, 'IRR', 52, 'sdrBW', 50, ...
               'lnaOn', false, 'lnaNF', 2, 'lnaGain', 20, 'filt', 0, 'cableLen', 15, 'cable100', 6.6, 'cable600', 16.5, ...
               'antModel', 'dipole', 'designMHz', 100, 'nElements', 1);
end

function a = antennaPreset(key)
% Antenna Toolbox models of the antennas you have (band from the datasheets).
    switch key
        case 'buwx16l'      % Digitek 01BUWX16L: UHF Ch 28-51, max 15 dBi, F/B > 19 dB, LTE filter above 694 MHz
            a = struct('name', "Digitek 01BUWX16L UHF Yagi", ...
                       'pol', 'H', ...
                       'antModel', 'yagi', 'designMHz', 606, 'nElements', 16, ...
                       'note', 'Antenna Toolbox 16-element Yagi-Uda designed at 606 MHz, centre of its 527-698 MHz band');
        case 'efm3'         % Digitek 01EFM3: FM 87.5-108 MHz, 3 elements, 5 dB forward gain, F/B > 15 dB
            a = struct('name', "Digitek 01EFM3 FM Yagi", 'pol', 'H', ...
                       'antModel', 'yagi', 'designMHz', 97.75, 'nElements', 3, ...
                       'note', ['Antenna Toolbox 3-element Yagi-Uda at 97.75 MHz (centre of 87.5-108 MHz), pointing ' ...
                                'up with horizontal elements; datasheet: 5 dB forward gain, F/B > 15 dB']);
        case 'edab'         % Digitek 01EDAB: Band III DAB+, 1 element, max 2 dBi, F/B not applicable
            a = struct('name', "Digitek 01EDAB DAB+ folded dipole", ...
                       'pol', 'V', ...
                       'antModel', 'dipoleFolded', 'designMHz', 205.5, 'nElements', 1, ...
                       'note', ['Antenna Toolbox folded dipole designed at 205.5 MHz (DAB+ 9A-9D); mounted vertically ' ...
                                'to match Brisbane DAB+; datasheet: 2 dBi']);
        otherwise
            a = [];
    end
end
%% altitude_curves.m
% Reflected-signal S/N against altitude, Cooby Creek vs UQ St Lucia, for the
% three antennas the model uses (one per band) and two targets:
%   Starlink  RCS 50 m^2   (orbit ~480 km: SpaceX moved its 550 km shells down during 2026)
%   ISS       RCS 400 m^2  (typical orbit ~400 km)
% Same model as the planner (leo_detectability.m, 'altitude' mode): the RCS is an
% equivalent conducting sphere sqrt(RCS/pi) (exact Mie series), straight along the
% antenna boresight (zenith); ITU-R P.372 noise per site; Longley-Rice terrain on
% the direct path; swamping of the SDR by every station in its capture bandwidth;
% Antenna Toolbox pattern; your SDR, amplifier, filter and cable.
%
% Each axis: one line per transmitter site (colour) and receive site (line
% style); each line is the best channel of that transmitter site in the band.
% Rows = antennas, columns = targets.
%
% Figures
%   1  S/N vs altitude (frames summed over tint seconds): generic half-wave dipoles
%      for FM, DAB+ and DTV
%   2  The same for the real Digitek antennas (01EFM3 FM Yagi, 01EDAB DAB+ folded
%      dipole, 01BUWX16L UHF DTV Yagi)
%   3  Highest altitude reaching kSigma, per antenna
%
% Needs leo_detectability.m and leo_inputs.xlsx in the same folder.
% First run computes terrain and antenna patterns (cached on disk afterwards).

clear; clc;

%% ===================== SETTINGS ===================================
sites   = {'Cooby Creek', 'UQ St Lucia'};
styles  = {'-', '--'};                   % line style per receive site
txSet   = 'seq';                         % 'seq' = all within 150 km; 'original' = the four sites of the old figure
maxTx   = 4;                             % transmitter sites per axis (the strongest)
targets = struct('name', {'Starlink', 'ISS'}, 'rcs', {50, 400}, 'orbitKm', {480, 400});   % RCS in m^2
altKm   = 100:10:2000;                   % altitudes (km)
tint    = 20;                            % s of frames summed (1 = single 1 s frame)
kSigma  = 3;                             % detection threshold
txVertical = 'paper';                    % 'paper' = Gtx 0.5 (Tingay 2013); 'measured' = -16 dB (LOFAR)
motionComp = false;                      % orbit-based motion correction (coherent 1 s frames)
useSavedHardware = true;                 % SDR, amplifier and cable from the app's Hardware tab if saved
elemAz = 90;                             % flat antennas' elements lie along this azimuth (deg from north;
                                         % 90 = east-west). A dipole is blind along its length: Mt Coot-tha
                                         % lies almost due west of UQ and due east of Cooby Creek.
refSeparate = false;                     % true = second antenna + SDR aimed at the transmitter for a clean
                                         % reference (otherwise the direct signal on the same antenna is the
                                         % reference, and a well-rejected direct signal makes a noisy one)

% The antennas used in the model (as on the map's best-site stars and the Load antenna list)
% Generic: a half-wave dipole for each band (Figure 1). Real: the Digitek antennas
% (Figure 2). All point straight up with their elements horizontal.
ant = struct('name', {'Half-wave FM dipole (100 MHz)', 'Half-wave DAB+ dipole (205.5 MHz)', 'Half-wave DTV dipole (606 MHz)', ...
                      'Digitek 01EFM3 FM Yagi (3 el)', 'Digitek 01EDAB DAB+ folded dipole (flat)', 'Digitek 01BUWX16L UHF Yagi'}, ...
             'short', {'FM dipole', 'DAB+ dipole', 'DTV dipole', ...
                       'Digitek FM Yagi (3 el)', 'Digitek DAB+ folded dipole', 'Digitek DTV Yagi (16 el)'}, ...
             'real', {false, false, false, true, true, true}, ...
             'antModel', {'dipole', 'dipole', 'dipole', 'yagi', 'dipoleFolded', 'yagi'}, ...
             'designMHz', {100, 205.5, 606, 97.75, 205.5, 606}, ...
             'nElements', {1, 1, 1, 3, 1, 16}, 'pol', {'H', 'H', 'H', 'H', 'H', 'H'});
% Digitek 01EFM3: 3-element FM Yagi, 87.5-108 MHz, 5 dB forward gain, F/B > 15 dB
% (datasheet); modelled as an Antenna Toolbox 3-element Yagi-Uda at the band centre,
% pointing straight up with its elements horizontal.
% The DAB+ dipole is mounted flat (horizontal): mounted vertically, as for broadcast
% reception, it has a null straight up. Flat, it also partly rejects the vertically
% polarised direct signal from the DAB+ transmitters.

%% ===================== HARDWARE ===================================
here = fileparts(mfilename('fullpath'));  if isempty(here), here = pwd; end
hw = struct('sdrName','RigExpert Fobos', 'NF',8, 'DR',82, 'maxIn',10, 'IRR',52, 'sdrBW',50, 'filt',0, 'lnaOn',false, ...
            'lnaNF',2, 'lnaGain',20, 'cableLen',15, 'cable100',6.6, 'cable600',16.5, 'refSeparate',false);
hf = fullfile(here, 'leo_hardware.mat');
if useSavedHardware && isfile(hf)
    try
        S = load(hf, 'hwSaved');
        for f = {'sdrName','NF','DR','maxIn','IRR','sdrBW','filt','lnaOn','lnaNF','lnaGain','cableLen','cable100','cable600'}
            if isfield(S.hwSaved, f{1}), hw.(f{1}) = S.hwSaved.(f{1}); end
        end
    catch
    end
end
if strcmpi(txVertical, 'paper'), gLab = 'G_{tx} = 0.5 (Tingay 2013)'; else, gLab = 'G_{tx} -16 dB (LOFAR)'; end

hw.refSeparate = refSeparate;

%% ===================== RUN THE MODEL ==============================
nA = numel(ant);  nS = numel(sites);  nT = numel(targets);
R = cell(nS, nA, nT);
for a = 1:nA
    c = hw;  for f = {'name','antModel','designMHz','nElements','pol'}, c.(f{1}) = ant(a).(f{1}); end
    for s = 1:nS
        for t = 1:nT
            cfg = struct('mode','altitude', 'site',sites{s}, 'txSet',txSet, 'receiver','custom', 'custom',c, ...
                         'rxPol',c.pol, 'antAz',mod(elemAz - 90, 360), 'antEl',90, 'altKm',altKm, 'kSigma',kSigma, ...
                         'rcs',targets(t).rcs, 'txVertical',txVertical, 'motionComp',motionComp, ...
                         'sdrBW_MHz',hw.sdrBW, 'filterRej_dB',hw.filt);
            R{s,a,t} = leo_detectability(cfg);
        end
    end
end

%% ===================== WHICH TRANSMITTER SITES PER ANTENNA ========
% the strongest transmitter sites for each antenna (over both receive sites, ISS)
txPick = cell(nA, 1);
for a = 1:nA
    names = strings(0);  best = [];
    for s = 1:nS
        r = R{s, a, nT};  T = r.table;
        if isempty(T), continue; end
        for q = 1:height(T)
            k = find(names == T.TxSite(q), 1);
            if isempty(k), names(end+1) = T.TxSite(q); best(end+1) = 0; k = numel(names); end %#ok<SAGROW>
            best(k) = max(best(k), max(r.snr(q,:)));
        end
    end
    [~, o] = sort(best, 'descend');
    txPick{a} = names(o(1:min(maxTx, numel(o))));
end
allTx = unique([txPick{:}], 'stable');
cols = lines(max(numel(allTx), 1));
siteAbbr = containers.Map({'Cooby Creek', 'UQ St Lucia'}, {'Cooby', 'UQ'});

%% ===================== FIGURE 1: S/N vs ALTITUDE ==================
yl = [1e-3 1e6];
maxAlt = NaN(nA, nT, numel(allTx), nS);
figSets = {find(~[ant.real]), 'Altitude curves - generic dipoles', 'Generic half-wave dipoles: '; ...
           find([ant.real]),  'Altitude curves - Digitek antennas', 'Digitek antennas: '};
for fi = 1:size(figSets, 1)
aSet = figSets{fi, 1};  if isempty(aSet), continue; end
figure('Color','w', 'Position', [40+30*fi 40 1500 330*numel(aSet)], 'Name', figSets{fi, 2});
tl = tiledlayout(numel(aSet), nT, 'TileSpacing','compact', 'Padding','compact');
title(tl, sprintf('%sS/N vs altitude, frames summed over %g s, %s%s  |  %s (solid) vs %s (dashed)', figSets{fi, 3}, ...
      tint, gLab, ternary(motionComp, ', motion correction', ''), sites{1}, sites{2}), 'FontSize', 12);
for a = aSet
    for t = 1:nT
        ax = nexttile(tl);  hold(ax, 'on');  box(ax, 'on');  grid(ax, 'on');
        hl = gobjects(0);  lab = {};
        for s = 1:nS
            r = R{s, a, t};  T = r.table;
            for k = 1:numel(txPick{a})
                sel = find(T.TxSite == txPick{a}(k));
                if isempty(sel), continue; end
                [~, j] = max(max(r.snr(sel,:), [], 2));  q = sel(j);     % this site's best channel
                y = r.snr(q,:) * sqrt(tint);  y(y <= 0) = NaN;
                if all(isnan(y)), continue; end
                ci = find(allTx == txPick{a}(k), 1);
                hl(end+1) = plot(ax, altKm, y, styles{s}, 'Color', cols(ci,:), 'LineWidth', 1.5); %#ok<SAGROW>
                lab{end+1} = sprintf('%s: %s %.1f MHz', siteAbbr(sites{s}), ...
                                     regexprep(char(T.Channel(q)), '\s*\(.*\)$', ''), T.MHz(q)); %#ok<SAGROW>
                h = find(y >= kSigma, 1, 'last');
                if ~isempty(h), maxAlt(a, t, ci, s) = altKm(h); end
            end
        end
        yline(ax, kSigma, 'k:', sprintf('%g\\sigma', kSigma), 'LabelHorizontalAlignment','left', 'HandleVisibility','off');
        xline(ax, targets(t).orbitKm, 'k-.', 'LineWidth', 1.2, 'HandleVisibility','off');
        set(ax, 'YScale','log');  xlim(ax, altKm([1 end]));  ylim(ax, yl);
        xlabel(ax, 'Altitude (km)');  ylabel(ax, sprintf('S/N (%g s)', tint));
        title(ax, sprintf('%s: %s (%g m^2)', ant(a).short, targets(t).name, targets(t).rcs));
        if isempty(hl)
            text(ax, mean(altKm([1 end])), 1, 'No usable channel (out of band or SDR overloaded)', ...
                 'HorizontalAlignment','center');
        else
            legend(ax, hl, lab, 'Location','eastoutside', 'FontSize', 7, 'Interpreter','none');
        end
    end
end
end

%% ===================== FIGURE 2 + TABLE: MAX ALTITUDE =============
figure('Color','w', 'Position', [80 80 1200 420], 'Name', 'Detection altitude limit');
tl2 = tiledlayout(1, nT, 'TileSpacing','compact', 'Padding','compact');
title(tl2, sprintf('Highest altitude with S/N \\geq %g\\sigma (%g s), best transmitter site per antenna', kSigma, tint));
for t = 1:nT
    ax = nexttile(tl2);
    v = squeeze(max(maxAlt(:, t, :, :), [], 3));          % nA x nS
    v(isnan(v)) = 0;
    bar(ax, v);  grid(ax, 'on');
    set(ax, 'XTickLabel', {ant.short}, 'XTickLabelRotation', 20);
    ylabel(ax, 'Altitude (km)');  ylim(ax, [0 altKm(end)]);
    yline(ax, targets(t).orbitKm, 'k-.', sprintf('%s orbit ~%g km', targets(t).name, targets(t).orbitKm));
    legend(ax, sites, 'Location', 'northeast');
    title(ax, sprintf('%s (RCS %g m^2)', targets(t).name, targets(t).rcs));
end
fprintf('\nHighest altitude (km) with S/N >= %g over %g s (0 = never):\n', kSigma, tint);
for a = 1:nA
    for t = 1:nT
        v = squeeze(max(maxAlt(a, t, :, :), [], 3));  v(isnan(v)) = 0;
        fprintf('  %-20s %-9s', ant(a).short, targets(t).name);
        fprintf('  %s %5.0f', sites{1}, v(1));  fprintf('   %s %5.0f\n', sites{2}, v(2));
    end
end

function out = ternary(c, a, b)
    if c, out = a; else, out = b; end
end
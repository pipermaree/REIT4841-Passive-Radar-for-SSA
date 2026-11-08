function api = leo_radar()
%LEO_RADAR  Radar propagation modelling: Antenna Toolbox antennas, RF Toolbox
%   receiver chain, direct path, swamping, cancellation and noise per channel, Mie
%   scattering, transmitter patterns, echo S/N along a pass and the best channel.
%   Returns handles to its functions, e.g. X = leo_radar(); X.bestChannel(...).
%   Part of the LEO passive-radar planner (main file: leo_detectability.m).
    persistent A
    if isempty(A)
        A = struct( ...
            'bestChannel', @bestChannel,  ...
            'cachedChannels', @cachedChannels,  ...
            'channelSetup', @channelSetup,  ...
            'dpiGrid', @dpiGrid,  ...
            'nMore', @nMore,  ...
            'objectSignal', @objectSignal);
    end
    api = A;
end

function [C, M] = cachedChannels(rx, rcv, md, P, say)
% Channel noise (needs terrain) and Mie tables are slow: compute once per
% site/receiver per MATLAB session.
    UTL = leo_utils();
    persistent store
    if isempty(store), store = containers.Map(); end
    key = sprintf('%s|%s|%s', rx.name, rcv.code, rcv.fp);
    if isKey(store, key)
        s = store(key);  C = s.C;  M = s.M;
        say('Using cached receiver model for %s, %s\n', rx.name, rcv.name);
        return
    end
    say('Setting up %s at %s (terrain and scattering tables, once per session)...\n', rcv.name, rx.name);
    t0 = tic;
    C = channelSetup(rx, md.ch, rcv, md.sdr, md.lna, md.cable, md.proc, P);
    t1 = toc(t0);
    M = mieTables(C);
    say('Receiver model: channels %.0f s, scattering tables %.0f s\n', t1, toc(t0) - t1);
    store(key) = struct('C', C, 'M', M);
    for q = 1:numel(C.idx)
        say('  %-28s %7.2f MHz  %6.1f kW  noise %8.2f Jy (1 s)  swamping +%4.1f dB  SDR in %6.1f dBm\n', ...
            UTL.chanName(md.ch(C.idx(q),:)), C.fMHz(q), C.ERP(q)/1e3, C.noise(q), C.swamp_dB(q), C.Pin_dBm(q));
    end
end

function b = bestChannel(p, el, req, C, M, rxE, rcv, P, dt)
% Best channel for one object: highest track-integrated S/N. With P.nChanSum = N > 1
% the N best channels are combined: each gives an independent map of the same object,
% and the optimum weighted sum of independent statistics has S/N sqrt(sum snr_q^2).
    UTL = leo_utils();
    nq = numel(C.idx);  snrQ = cell(nq, 1);  dq = -Inf(nq, 1);
    b = struct('d',-Inf);
    for q = 1:nq
        [snr, rngEx, dop] = objectSignal(p, req, C, q, M, rxE, P, dt);
        snr(el < 0) = 0;  snrQ{q} = snr;
        [d, win] = bestTrack(snr, dt, P.trackLens);  dq(q) = d;
        if d > b.d
            b = struct('d',d, 'win',win, 'q',q, 'snr',snr, 'rngEx',rngEx, 'dop',dop, 'nCh',1);
        end
    end
    nC = min(UTL.fieldOr(P, 'nChanSum', 1), nq);
    if nC > 1
        [~, o] = sort(dq, 'descend');
        snr = sqrt(sum(cat(2, snrQ{o(1:nC)}).^2, 2));
        [d, win] = bestTrack(snr, dt, P.trackLens);
        b.d = d;  b.win = win;  b.snr = snr;  b.nCh = nC;
    end
end

function C = channelSetup(rx, ch, rcv, sdr, lna, cable, proc, P)
% Per-channel transmitter data and 1 s detection noise (Jy) for this receiver.
    TER = leo_terrain();  UTL = leo_utils();
    c = 299792458;  kB = 1.380649e-23;  Re = 6371e3;  C = struct();
    A = rcv.A;  fAll = [ch{:,2}]';
    idx = find(fAll >= A.fMHz(1) & fAll <= A.fMHz(2));  chA = ch(idx,:);  n = numel(idx);
    fMHz = fAll(idx);  B = cellfun(@(b) P.Bband(b), chA(:,7));  lam = c./(fMHz*1e6);
    ERP = [chA{:,3}]';
    % direct path at the receiver (spherical Earth, as in the other scripts)
    [rxS, Er, Nr, Ur] = UTL.enuBasis(rx.lat, rx.lon, Re);
    bAz = UTL.fieldOr(A, 'boreAz', 0);  bEl = UTL.fieldOr(A, 'boreEl', 90);    % antenna pointing (default straight up)
    txS = zeros(n,3);
    for q = 1:n, txS(q,:) = UTL.enuBasis(chA{q,4}, chA{q,5}, Re); end
    vtx = txS - rxS;  d = vecnorm(vtx,2,2);
    txPol = repmat('M', n, 1);
    for q = 1:n
        p11 = '';  if size(chA, 2) >= 11, p11 = chA{q,11}; end
        if (ischar(p11) || isstring(p11)) && strlength(string(p11)) > 0, p11 = char(p11);  txPol(q) = upper(p11(1));
        elseif strcmp(chA{q,7}, 'DTV'), txPol(q) = 'H'; else, txPol(q) = 'V'; end
    end
    % Antenna Toolbox: realized gain (directivity x mismatch; feed matched at the design frequency) for H and V
    % polarisation in every direction, for this antenna as mounted and pointed;
    % polarisation match to each transmitter is part of the pattern
    AR = antResponse(A, fMHz, bAz, bEl);
    AR.eDir = antElementDir(A, bAz, bEl);                    % for the echo's polarisation match
    dirTx = [vtx*Er', vtx*Nr', vtx*Ur'] ./ d;                % ENU unit vectors rx -> tx
    relTx = zeros(n,1);
    for q = 1:n, relTx(q) = antGainDir(AR, q, dirTx(q,:), txPol(q)) / AR.gPk(q); end
    gPk = AR.gPk(:);
    % transmitter's own azimuth pattern towards the receiver (pattern data / DA assumption);
    % the direct path is in the main beam of the elevation pattern
    gTxRx = ones(n,1);  hasPat = false(n,1);
    for q = 1:n
        [~, E, N] = UTL.enuBasis(chA{q,4}, chA{q,5}, Re);
        v = -vtx(q,:) / d(q);                                   % tx -> rx
        az = mod(atan2d(v*E', v*N'), 360);
        [ga, hasPat(q)] = txAzGain(chA(q,:), az, P);
        if ~hasPat(q) && numel(chA(q,:)) >= 10 && strcmp(chA{q,10}, 'DA')
            ga = 10^(-P.daRxAtten_dB/10);
        end
        gTxRx(q) = ga;
    end
    Tgal = 290 * 10.^((52.0 - 23.0*log10(fMHz))/10);
    azs = (0:10:350)';  hor = cosd(azs)*Nr + sind(azs)*Er;              % horizon directions
    horENU = [hor*Er', hor*Nr', hor*Ur'];                     % response to ground-level noise
    horRel = zeros(n,1);
    for q = 1:n, horRel(q) = mean(antGainDir(AR, q, horENU, 'T')) / AR.gPk(q); end
    Tman = arrayfun(@(f) manmadeT(f, rx.env), fMHz) .* horRel;
    Aeff = gPk .* lam.^2 / (4*pi);
    Lc = 10.^(cable.length/100 * interp1(cable.fMHz, cable.dBper100m, fMHz, 'linear','extrap')/10);
    F = chainNoiseFactor(10*log10(Lc), lna, sdr, fMHz, B);     % RF Toolbox rfbudget cascade
    spillEff = AR.spill(:);                                    % share of the pattern below the horizon
    Tsys0 = Tgal + Tman + 290*spillEff + 290*(F-1);
    if lna.on, Gch = 10^(lna.gain/10) ./ Lc; else, Gch = 1 ./ Lc; end
    if P.motionComp
        Tc = P.tint * ones(n,1);
    else                                                      % reference pass: physics, not assumed
        accRef = 2 * P.vRef^2 / P.hRef;                       % bistatic range acceleration overhead (m/s^2)
        Tc = min(P.tint, min((c ./ B) / P.vRef, 1 ./ sqrt(accRef ./ lam)));
    end
    % Blind search: coherent over the frame without the orbit. Range migration is undone
    % for every target at once by the keystone transform (no trials); the change of
    % Doppler is found by trying Doppler rates from -amax/lambda to +amax/lambda in steps
    % of 1/T^2 (T = frame). Testing M trials at the same false-alarm rate raises the
    % threshold from k to k' = sqrt(2) erfcinv(2 Pfa / M): that ratio is the search loss.
    searchLoss = ones(n,1);
    if isfield(P, 'blind') && P.blind
        amax = 2 * P.vRef^2 / P.hRef;                         % largest LEO range acceleration
        Mtr  = max(1, ceil(2 * amax ./ lam * P.tint^2) + 1);  % Doppler-rate trials
        pfa  = 0.5 * erfc(P.kSigma / sqrt(2));
        searchLoss = sqrt(2) * erfcinv(2 * pfa ./ Mtr) / P.kSigma;
    end
    gainV = P.arrayN ./ searchLoss;                           % applied to the object's S/N
    decT = cellfun(@(b) proc.decodeSNR(b), chA(:,7));
    cancelUsed = proc.cancel_dB * ones(n,1);                  % set by chanNoise (per channel with ECA-B)
    Sdir0 = ERP ./ (4*pi*d.^2) ./ B / 1e-26 .* relTx .* gTxRx;   % Jy, free space

    % Terrain (slow) only for channels that could make the final list: the
    % best figure of merit a channel could reach for ANY terrain loss (-6 to
    % 90 dB) must be within P.terrainScreen_dB of the
    % maxChannels-th best. The rest keep free-space values.
    terr = zeros(n,1);  terrOK = false(n,1);
    if P.terrain
        fb = Inf(n,1);  need = true(n,1);
        if n > P.maxChannels
            fb = zeros(n,1);
            for Ls = -6:3:90
                fb = max(fb, ERP ./ B ./ chanNoise(Sdir0 * 10^(-Ls/10), false));
            end
            srt = sort(fb, 'descend');
            need = fb >= srt(P.maxChannels) * 10^(-P.terrainScreen_dB/10);
        end
        try
            tT = tic;
            for it = 1:20       % repeat until no unchecked channel could still make the final list
                todo = need & ~terrOK;
                if ~any(todo), break; end
                terr(todo) = TER.terrainExcessLoss(rx, chA(todo,:), P);  terrOK(todo) = true;
                fa = ERP ./ B ./ chanNoise(Sdir0 .* 10.^(-terr/10), false);
                fc = sort(fa(terrOK), 'descend');  kth = fc(min(P.maxChannels, numel(fc)));
                need = terrOK | fb >= kth * 10^(-P.terrainScreen_dB/10);
            end
            fprintf('Terrain for %s: %d of %d channels needed it (%.0f s)\n', rx.name, sum(terrOK), n, toc(tT));
        catch err
            warning('Terrain loss failed (%s); using free space.', err.message);
        end
    end
    Sdir = Sdir0 .* 10.^(-terr/10);                                % Jy
    [noise, base, Pin, Tsys, Tblk] = chanNoise(Sdir, true);
    Swamping_dB = 10*log10(Tsys ./ (Tsys - Tblk));                % noise added by the other stations
    Cancel_dB = cancelUsed(:);
    % noise for other cancellation values ('altitude' mode sweep)
    noiseSweep = zeros(n, 0);
    if isfield(P, 'cancelSweep') && ~isempty(P.cancelSweep)
        noiseSweep = zeros(n, numel(P.cancelSweep));
        for kk = 1:numel(P.cancelSweep), noiseSweep(:,kk) = chanNoise(Sdir, true, P.cancelSweep(kk)); end
    end

    % keep the strongest channels (ERP per Hz over noise)
    fom = ERP ./ B ./ noise;
    [~, oAll] = sort(fom, 'descend');  o = oAll(1:min(P.maxChannels, n));
    % every channel in the antenna band, for the site map
    Rank = zeros(n,1);  Rank(oAll) = (1:n)';
    DirectAboveNoise_dB = 10*log10(Sdir ./ (2*kB*Tsys ./ Aeff / 1e-26));
    SDRin_dBm = Pin;
    Channel = string(arrayfun(@(k) UTL.chanName(chA(k,:)), (1:n)', 'UniformOutput', false));
    % S/N per 1 s frame for a 1 m^2 object 500 km straight above the site (site score)
    hOv = 500e3;  pOv = rxS / norm(rxS) * (Re + hOv);  OverheadSNR = zeros(n,1);
    for q = 1:n
        [~, E, N, U] = UTL.enuBasis(chA{q,4}, chA{q,5}, Re);
        vt = pOv - txS(q,:);  Rt = norm(vt);  u = vt / Rt;
        el = asind(u*U');  az = mod(atan2d(u*E', u*N'), 360);
        if el <= 0, continue; end
        g = txAzGain(chA(q,:), az, P) * txVertGain(P);
        S = ERP(q) * g / ((4*pi)^2 * Rt^2 * hOv^2) / B(q) / 1e-26;
        OverheadSNR(q) = S / noise(q) * gainV(q);
    end
    C.all = table(Rank, Channel, fMHz, ERP/1e3, d/1e3, terr, terrOK, DirectAboveNoise_dB, SDRin_dBm, ...
                  Swamping_dB, Cancel_dB, noise, OverheadSNR, [chA{:,4}]', [chA{:,5}]', ...
                  B, Tc, [chA{:,8}]', lam, string(chA(:,7)), ...
                  'VariableNames', {'Rank','Channel','MHz','ERP_kW','Dist_km','TerrainLoss_dB','TerrainComputed', ...
                                    'DirectAboveNoise_dB','SDRin_dBm','Swamping_dB','Cancel_dB', ...
                                    'Noise_Jy_1s','OverheadSNR_1m2','Lat','Lon','B_Hz','Tc_s','TxHeight_m','Lambda_m','Band'});
    C.all = sortrows(C.all, 'Rank');
    C.idx = idx(o);  C.fMHz = fMHz(o);  C.B = B(o);  C.lam = lam(o);  C.ERP = ERP(o);  C.noise = noise(o);
    C.Tc = Tc(o);  C.dynTc = ~P.motionComp;
    C.base = base(o);  C.noiseSweep = noiseSweep(o,:);
    C.rows = chA(o,:);                                  % for the transmitter pattern towards the object
    C.Pin_dBm = Pin(o);  C.swamp_dB = Swamping_dB(o);  C.gain = gainV(o);  C.searchLoss = searchLoss(o);
    C.gTxRx = gTxRx(o);  C.txPol = txPol(o);  C.antR = antSubset(AR, o);
    C.txE = zeros(numel(o),3);  C.txUp = zeros(numel(o),3);
    for q = 1:numel(o)
        [C.txE(q,:), C.txUp(q,:)] = UTL.wgs84(chA{o(q),4}, chA{o(q),5}, chA{o(q),8});
    end

    function [noise, base, Pin, Tsys, Tblk] = chanNoise(Sd, withSwamp, cancelDB)
    % 1 s noise (Jy) per channel for direct-path flux Sd.
    % cancelDB (optional) replaces the assumed direct-path cancellation.
        sweep = nargin >= 3;
        if ~sweep, cancelDB = proc.cancel_dB; end
        % Swamping: every other station inside the capture bandwidth reaches the ADC
        % too; the SDR's blocking dynamic range is taken per channel: the noise floor in
        % each channel's bandwidth is DR dB below the other stations' total power
        % (referred to the antenna). A filter in front of the SDR reduces the other
        % stations by filtRej_dB.
        Pw  = Sd * 1e-26 .* B .* Aeff;                        % W at the antenna terminals
        Tblk = zeros(n,1);  Pin = zeros(n,1);
        for qq = 1:n
            Poth = 0;
            if withSwamp
                oth = abs(fMHz - fMHz(qq)) <= sdr.bw_MHz/2;  oth(qq) = false;
                Poth = sum(Pw(oth)) * 10^(-sdr.filtRej_dB/10);
                Tblk(qq) = Poth * 10^(-sdr.DR/10) / (kB * B(qq));
            end
            Pin(qq) = 10*log10((Pw(qq) + Poth) * Gch(qq)) + 30;   % everything at the SDR input (dBm)
        end
        Tsys = Tsys0 + Tblk;
        SEFD = 2*kB*Tsys ./ Aeff / 1e-26;
        DN   = Sd ./ SEFD;
        refSNR = min(DN, 10^(sdr.DR/10));
        dec  = 10*log10(refSNR) >= decT;
        refF = refSNR ./ (1 + refSNR);  refF(dec) = 1;
        sepRef = isfield(proc, 'refSeparate') && proc.refSeparate;
        if sepRef, refF(:) = 1; end
        if isfield(sdr, 'IRR'), img = sdr.imgSelf * 10^(-sdr.IRR/10); else, img = 0; end
        % direct-path cancellation per channel (dB)
        cancelV = cancelDB * ones(n,1);
        if ~sweep && strcmp(P.cancelMethod, 'eca')
            % ECA-B: least squares on delayed copies of the reference, batch by batch.
            % Limited by (1) with a separate reference antenna, the noise on that reference:
            % suppression <= 1 + its S/N (none when DAB+/DVB-T is decoded); (2) a practical
            % ceiling (clutter extent vs taps, channel changes within a batch, oscillator drift).
            % The reference-noise limit applies only to a SEPARATE reference channel, whose
            % noise is independent of the surveillance noise. With one antenna the reference
            % IS the received signal (same noise); its quality loss is already counted by refF.
            limRef = Inf(n,1);
            if sepRef
                % reference antenna: the same model aimed at the transmitter, so it sees the
                % transmitter 1/relTx stronger than the surveillance antenna does (pattern)
                limRef = 10*log10(1 + min(DN ./ max(relTx(:), 1e-6), 10^(sdr.DR/10)));
                limRef(dec) = Inf;
            end
            cancelV = min(P.eca.ceiling_dB, limRef);
        end
        cancelUsed = cancelV;
        Teff = 1 + DN .* (10.^(-cancelV/10) + 10^(-sdr.DR/10) + img);
        noise = SEFD .* Teff ./ (B .* sqrt(Tc * P.tint)) ./ refF;
        % residual direct signal at zero range / zero Doppler, in units of the
        % map's mean noise per cell (same processing gain as a target)
        base  = DN .* (10.^(-cancelV/10) + 10^(-sdr.DR/10) + img) .* B .* sqrt(Tc * P.tint);
        noise(Pin > sdr.maxIn_dBm) = Inf;                     % SDR overloaded: unusable
    end

end

function M = mieTables(C)
% Bistatic RCS lookup per channel: equivalent sphere radius x cos(scattering angle).
% A table depends only on the wavelength, so tables are kept in memory and in
% mie_cache.mat next to this file (delete it to recompute).
    UTL = leo_utils();
    persistent mem
    cacheFile = UTL.modelPath('mie_cache.mat');
    if isempty(mem)
        mem = containers.Map();
        if isfile(cacheFile)
            try, S = load(cacheFile, 'mem'); mem = S.mem; catch, end
        end
    end
    M.logr = linspace(log10(0.01), log10(30), 60);
    M.cth  = linspace(-1, 1, 41);
    M.tab  = cell(numel(C.fMHz),1);  changed = false;
    for q = 1:numel(C.fMHz)
        key = sprintf('%.3f', C.fMHz(q));
        if ~isKey(mem, key)
            k = 2*pi/C.lam(q);  T = zeros(numel(M.logr), numel(M.cth));
            for i = 1:numel(M.logr)                   % all angles at once per radius
                T(i,:) = mieRCS_PEC(k*10^M.logr(i), M.cth, C.lam(q));
            end
            mem(key) = T;  changed = true;
        end
        M.tab{q} = mem(key);
    end
    if changed, try, save(cacheFile, 'mem'); catch, end, end
end

function [snr, rngEx, dop] = objectSignal(p, req, C, q, M, rxE, P, dt)
% 1 s snapshot S/N, bistatic range excess (km) and Doppler (Hz) vs time.
    tx = C.txE(q,:);
    vT = p - tx;   Rt = vecnorm(vT,2,2);
    vR = rxE - p;  Rr = vecnorm(vR,2,2);
    cth = max(-1, min(1, sum((vT./Rt) .* (vR./Rr), 2)));
    lr  = min(max(log10(req), M.logr(1)), M.logr(end));
    sig = interp2(M.cth, M.logr, M.tab{q}, cth, lr*ones(size(cth)), 'linear');
    if req < 10^M.logr(1)                    % Rayleigh scaling below the table
        sig = sig * (req/10^M.logr(1))^6;
    end
    up = rxE / norm(rxE);  Eo = cross([0 0 1], up);  Eo = Eo / norm(Eo);  No = cross(up, Eo);
    u = (p - rxE) ./ Rr;                                       % ECEF unit vectors rx -> object
    dirO = [u*Eo', u*No', u*up'];
    tp = C.txPol(q);
    if tp == 'M'
        gO = antGainDir(C.antR, q, dirO, 'T');
    else
        % Polarisation of the echo, from the geometry (not the receiver's local H/V,
        % which is undefined straight overhead): the transmitter's field is horizontal
        % (H) or in the vertical plane (V) at the transmitter, perpendicular to its path
        % to the object; the sphere re-radiates it perpendicular to the path to the
        % receiver; the receive antenna's H and V gains weight its components there.
        % A fraction echoXpol of the power is depolarised by the (non-spherical) object.
        % The receive antenna's own polarisation in that direction is its element
        % direction projected across the path (wire antennas: dipole, Yagi).
        k  = vT ./ Rt;                                         % transmitter -> object
        h  = cross(repmat(C.txUp(q,:), size(k,1), 1), k, 2);   % horizontal at the tx, across the path
        h  = h ./ max(vecnorm(h,2,2), 1e-12);
        if tp == 'H', e = h; else, e = cross(k, h, 2); end     % incident field direction
        sc = -u;                                               % scattered wave: object -> receiver
        es = e - sum(e .* sc, 2) .* sc;  es = es ./ max(vecnorm(es,2,2), 1e-12);
        esE = [es*Eo', es*No', es*up'];                        % in East-North-Up
        ea = C.antR.eDir;                                      % receive element direction (ENU)
        pa = ea - (dirO * ea') .* dirO;  pa = pa ./ max(vecnorm(pa,2,2), 1e-12);
        m  = sum(pa .* esE, 2).^2;                             % polarisation match (0..1)
        gO = antGainDir(C.antR, q, dirO, 'T') .* (m + P.echoXpol * (1 - m));
    end
    rel = gO / C.antR.gPk(q);
    gTx = txGainToObject(vT ./ Rt, C, q, P);
    S = C.ERP(q) * gTx .* sig ./ ((4*pi)^2 * Rt.^2 .* Rr.^2) / C.B(q) / 1e-26 .* rel;
    txVis = sum(vT .* C.txUp(q,:), 2) > 0;   % above the transmitter's horizon
    rxVis = ((p - rxE) ./ Rr) * up' > 0;      % and above the receiver's horizon
    S(~txVis | ~rxVis) = 0;
    snr = S / C.noise(q);
    if isfield(C, 'gain'), snr = snr * C.gain(q); end         % array and blind-search loss
    Rb = norm(tx - rxE);
    rngEx = (Rt + Rr - Rb) / 1e3;
    dop = -gradient(Rt + Rr, dt) / C.lam(q);
    if isfield(C, 'dynTc') && C.dynTc && numel(dop) > 2
        % coherent time at each moment from this pass's own range rate and Doppler rate
        rr  = abs(dop) * C.lam(q);                            % bistatic range rate (m/s)
        fdr = abs(gradient(dop, dt));                         % Doppler rate (Hz/s)
        TcN = min(P.tint, min(299792458 / C.B(q) ./ max(rr, 1e-3), 1 ./ sqrt(max(fdr, 1e-6))));
        snr = snr .* sqrt(TcN / C.Tc(q));                     % S/N scales as sqrt(coherent time)
    end
end

function g = txGainToObject(u, C, q, P)
% Transmitter gain towards the object (u = unit vectors tx -> object, n x 3),
% relative to the licensed maximum ERP.
    up = C.txUp(q,:);
    E = cross([0 0 1], up);  E = E / norm(E);  N = cross(up, E);
    az = mod(atan2d(u * E', u * N'), 360);
    g = txAzGain(C.rows(q,:), az, P) .* txVertGain(P);
end

function [g, has] = txAzGain(row, az, P)
% Azimuth pattern from P.txPat (keys: 'CALL (Area)', callsign or area), else 1.
    UTL = leo_utils();
    g = ones(size(az));  has = false;
    if P.txPat.Count == 0, return; end
    keysTry = {upper(UTL.chanName(row)), upper(row{6})};
    if numel(row) >= 9, keysTry{end+1} = upper(row{9}); end
    for k = 1:numel(keysTry)
        if isKey(P.txPat, keysTry{k})
            pt = P.txPat(keysTry{k});
            a = [pt(:,1) - 360; pt(:,1); pt(:,1) + 360];  L = repmat(pt(:,2), 3, 1);
            g = 10.^(-interp1(a, L, az, 'linear') / 10);  has = true;
            return
        end
    end
end

function g = txVertGain(P)
% Transmitter gain towards objects relative to its licensed ERP (the direct path
% gets the full ERP):
%   'paper':    P.Gtx = 0.5 (Tingay et al. 2013)
%   'measured': 10^(P.Gmeas_dB/10), -16 dB (Jedrzejewski et al. 2025, LOFAR)
    if strcmp(P.txVertical, 'paper'), g = P.Gtx; else, g = 10^(P.Gmeas_dB/10); end
end

function s = nMore(b)
% ' + N more' when several channels are combined.
    s = "";
    if isfield(b, 'nCh') && b.nCh > 1, s = sprintf(" + %d more", b.nCh - 1); end
end

function [dBest, win] = bestTrack(snr, dt, lens)
% Best detection statistic from summing 1 s snapshots over a window.
% lens = list of windows to try (s), or a single fixed window.
    if isscalar(lens)
        N = min(max(1, round(lens/dt)), numel(snr));
        dBest = max(movsum(snr, N, 'Endpoints','discard')) * dt / sqrt(N*dt);
        win = N*dt;
        return
    end
    dBest = max(snr);  win = 1;
    for L = lens(lens > 1)
        N = max(1, round(L/dt));
        if N > numel(snr), break; end
        d = max(movsum(snr, N, 'Endpoints','discard')) * dt / sqrt(N*dt);
        if d > dBest, dBest = d;  win = L; end
    end
end

function T = manmadeT(fMHz, env)
% ITU-R P.372 median man-made noise temperature (K).
    switch lower(env)
        case 'business',    cc = [76.8 27.7];
        case 'residential', cc = [72.5 27.7];
        case 'rural',       cc = [67.2 27.7];
        case 'quietrural',  cc = [53.6 28.6];
        case 'none',        T = 0; return
        otherwise, error('Unknown environment "%s"', env);
    end
    T = 290 * 10^((cc(1) - cc(2)*log10(fMHz))/10);
end

function sigma = mieRCS_PEC(x, cosTheta, lambda)
% Bistatic RCS of a perfectly conducting sphere, size parameter x = k*r, for a row
% of scattering angles cosTheta (the Bessel terms are computed once for all of them).
% Unpolarised average: sigma = lambda^2/pi * (|S1|^2 + |S2|^2)/2.
    cosTheta = cosTheta(:).';  nA = numel(cosTheta);
    N = ceil(x + 4*x^(1/3) + 2);        % Wiscombe truncation
    n = (1:N).';
    jn = sphj(n, x);    yn = sphy(n, x);
    jm = sphj(n-1, x);  ym = sphy(n-1, x);
    hn = jn + 1i*yn;    hm = jm + 1i*ym;
    psi  = x*jn;           xi  = x*hn;
    dpsi = x*jm - n.*jn;   dxi = x*hm - n.*hn;
    a = dpsi ./ dxi;
    b = psi  ./ xi;
    p = zeros(N+1, nA);  t = zeros(N+1, nA);   % row m+1 holds order m, one column per angle
    p(2,:) = 1;
    for m = 2:N
        p(m+1,:) = (2*m-1)/(m-1)*cosTheta.*p(m,:) - m/(m-1)*p(m-1,:);
    end
    for m = 1:N
        t(m+1,:) = m*cosTheta.*p(m+1,:) - (m+1)*p(m,:);
    end
    pn = p(2:end,:);  tn = t(2:end,:);
    w  = (2*n+1) ./ (n.*(n+1));
    S1 = sum(w .* (a.*pn + b.*tn), 1);
    S2 = sum(w .* (a.*tn + b.*pn), 1);
    sigma = lambda^2/pi * (abs(S1).^2 + abs(S2).^2) / 2;
end

function j = sphj(n, x), j = sqrt(pi/(2*x)) * besselj(n+0.5, x); end

function y = sphy(n, x), y = sqrt(pi/(2*x)) * bessely(n+0.5, x); end

function G = dpiGrid(md, rcv, rx, half)
% Free-space total direct-path power at the antenna terminals (dBm) over a
% grid around the site: every channel in the antenna band, mean antenna gain at
% the horizon, no terrain. A quick guide to where strong
% transmitters are; the site table has the full calculation.
    UTL = leo_utils();
    c = 299792458;  A = rcv.A;  ch = md.ch;
    f = [ch{:,2}]';  erp = [ch{:,3}]';  la = [ch{:,4}]';  lo = [ch{:,5}]';
    inB = f >= A.fMHz(1) & f <= A.fMHz(2);  gdB = zeros(size(f));
    k = find(inB);
    AR = antResponse(A, f(k), UTL.fieldOr(A, 'boreAz', 0), UTL.fieldOr(A, 'boreEl', 90));
    hz = [sind(0:10:350)', cosd(0:10:350)', zeros(36,1)];
    for i = 1:numel(k), gdB(k(i)) = 10*log10(mean(antGainDir(AR, i, hz, 'T'))); end
    step = half / 50;
    [LO, LA] = meshgrid(rx.lon + (-half:step:half), rx.lat + (-half:step:half));
    Pw = zeros(size(LA));
    for k = find(inB)'
        dk = max(111.2e3 * hypot(LA - la(k), (LO - lo(k)) .* cosd(LA)), 1e3);
        Aeff = 10^(gdB(k)/10) * (c/(f(k)*1e6))^2 / (4*pi);
        Pw = Pw + erp(k) ./ (4*pi*dk.^2) * Aeff;
    end
    G = struct('lat', LA, 'lon', LO, 'PdBm', 10*log10(max(Pw, 1e-30)) + 30, ...
               'note', 'Free space, mean antenna gain at the horizon, no terrain');
end

function F = chainNoiseFactor(LcdB, lna, sdr, fMHz, B)
% Receiver-chain noise factor per channel with RF Toolbox rfbudget: (masthead
% amplifier) -> cable -> SDR. The cable is a passive stage (gain -L, NF L).
    UTL = leo_utils();
    if ~UTL.hasFcn('rfbudget') || ~UTL.hasFcn('amplifier')
        error('The receiver chain uses RF Toolbox (rfbudget, amplifier), which is not available. Run ver.');
    end
    persistent memo
    if isempty(memo), memo = containers.Map(); end
    n = numel(fMHz);  F = zeros(n,1);
    for q = 1:n
        key = sprintf('%d|%g|%g|%g|%g|%g|%g', lna.on, lna.NF, lna.gain, sdr.NF, LcdB(q), fMHz(q), B(q));
        if isKey(memo, key), F(q) = memo(key); continue; end      % same chain at every site
        % fresh elements every channel: an rfbudget takes ownership of its elements
        sd  = amplifier('Name', 'SDR', 'Gain', 0, 'NF', sdr.NF);
        cab = amplifier('Name', 'Cable', 'Gain', -LcdB(q), 'NF', LcdB(q));
        if lna.on
            el = [amplifier('Name', 'LNA', 'Gain', lna.gain, 'NF', lna.NF), cab, sd];
        else
            el = [cab, sd];
        end
        b = rfbudget(el, fMHz(q)*1e6, -100, B(q));
        F(q) = 10^(b.NF(end)/10);  memo(key) = F(q);
    end
end

function R = antResponse(A, fMHz, bAz, bEl)
% Antenna Toolbox model of the receive antenna: realized gain (directivity x
% mismatch to a feed matched at the design frequency; PEC elements, so gain = directivity) for H and V
% polarisation on a 5-degree az/el grid in the local East-North-Up frame, for
% each frequency, with the antenna mounted (pol) and pointed (bAz, bEl).
% Cached in memory and in antenna_cache.mat next to this file.
    UTL = leo_utils();
    persistent mem
    if ~UTL.hasFcn('dipole')
        error('The receive antenna model needs Antenna Toolbox, which is not available (run ver to check).');
    end
    cacheFile = UTL.modelPath('antenna_cache.mat');
    if isempty(mem)
        mem = containers.Map();
        if isfile(cacheFile)
            try, S = load(cacheFile, 'mem'); mem = S.mem; catch, end
        end
    end
    azg = -180:5:180;  elg = -90:5:90;
    key = sprintf('%s|%g|%d|%s|%g|%g|matched', A.model, A.designMHz, A.nEl, A.pol, bAz, bEl);
    fr = round(fMHz(:) * 10) / 10;  [fu, ~, iu] = unique(fr);
    ant = [];  changed = false;  Gu = cell(numel(fu), 1);  Z0 = [];
    for k = 1:numel(fu)
        ck = sprintf('%s|%.1f', key, fu(k));
        if ~isKey(mem, ck)
            if isempty(ant), ant = buildAntenna(A, bAz, bEl); end
            fz = fu(k) * 1e6;
            dh = pattern(ant, fz, azg, elg, 'Type', 'directivity', 'Polarization', 'H');
            dv = pattern(ant, fz, azg, elg, 'Type', 'directivity', 'Polarization', 'V');
            if ~isequal(size(dh), [numel(elg) numel(azg)]), dh = dh.';  dv = dv.'; end   % rows = elevation
            % feed matched at the design frequency (balun / matching section, as fitted to
            % real antennas: a folded dipole's ~290 ohm needs a 4:1 balun), so mismatch only
            % grows away from the design frequency
            if isempty(Z0), Z0 = impedance(ant, A.designMHz * 1e6); end
            Z = impedance(ant, fz);  mm = 1 - abs((Z - conj(Z0)) / (Z + Z0))^2;
            mem(ck) = struct('GH', single(10.^(dh/10) * mm), 'GV', single(10.^(dv/10) * mm));
            changed = true;
        end
        Gu{k} = mem(ck);
    end
    if changed, try, save(cacheFile, 'mem'); catch, end, end
    n = numel(fMHz);  R = struct('az', azg, 'el', elg, 'GH', {cell(n,1)}, 'GV', {cell(n,1)}, ...
                                 'gPk', zeros(n,1), 'spill', zeros(n,1));
    w = cosd(elg(:)) * ones(1, numel(azg));                     % solid-angle weight
    for q = 1:n
        g = Gu{iu(q)};  R.GH{q} = double(g.GH);  R.GV{q} = double(g.GV);
        T = R.GH{q} + R.GV{q};
        R.gPk(q) = max(T(:));
        below = elg(:) < 0;
        R.spill(q) = sum(T(below,:) .* w(below,:), 'all') / sum(T .* w, 'all');
    end
end

function R = antSubset(R, o)
    R.GH = R.GH(o);  R.GV = R.GV(o);  R.gPk = R.gPk(o);  R.spill = R.spill(o);
end

function g = antGainDir(R, q, dirENU, pol)
% Realized gain (linear) of channel q's antenna response towards ENU unit vectors
% (m x 3) for polarisation 'H', 'V' or 'T' (total, for mixed or unpolarised).
    az = atan2d(dirENU(:,2), dirENU(:,1));                      % toolbox azimuth: from East towards North
    el = asind(max(-1, min(1, dirENU(:,3))));
    switch pol
        case 'H', G = R.GH{q};
        case 'V', G = R.GV{q};
        otherwise, G = R.GH{q} + R.GV{q};
    end
    g = interp2(R.az, R.el, G, az, el, 'linear');
    g(isnan(g)) = 0;
end

function e = antElementDir(A, bAz, bEl)
% Direction (East-North-Up) the antenna's elements are mounted along, as set by
% buildAntenna: horizontal across the pointing azimuth (pol 'H') or vertical /
% in the vertical plane through the beam (pol 'V').
    U = [0 0 1];  hz = [sind(bAz + 90), cosd(bAz + 90), 0];
    if any(strcmp(A.model, {'dipole', 'dipoleFolded'}))
        if upper(A.pol(1)) == 'V', e = U; else, e = hz; end
    else
        b = [cosd(bEl)*sind(bAz), cosd(bEl)*cosd(bAz), sind(bEl)];
        if abs(b(3)) > 0.999, eH = hz; else, eH = cross(U, b);  eH = eH / norm(eH); end
        if upper(A.pol(1)) == 'V', e = cross(b, eH);  e = e / norm(e); else, e = eH; end
    end
end

function ant = buildAntenna(A, bAz, bEl)
% Antenna Toolbox object designed at A.designMHz, then rotated so that its main
% beam points to (bAz, bEl) and its elements lie horizontal (pol 'H') or vertical
% ('V'). The toolbox frame is taken as x = East, y = North, z = Up.
    f0 = A.designMHz * 1e6;
    switch A.model
        case 'dipole',       ant = design(dipole, f0);
        case 'dipoleFolded', ant = design(dipoleFolded, f0);
        case 'loop',         ant = design(loopCircular, f0);
        case 'yagi'
            ant = yagiUda;
            try, ant.NumDirectors = max(1, A.nEl - 2); catch, end
            ant = design(ant, f0);
        otherwise, error('Unknown antenna model "%s".', A.model);
    end
    % as designed: main-beam direction b0 and element (E-field) direction e0
    azg = -180:5:180;  elg = -90:5:90;
    D = pattern(ant, f0, azg, elg, 'Type', 'directivity');
    if ~isequal(size(D), [numel(elg) numel(azg)]), D = D.'; end
    [~, im] = max(D(:));  [ie, ia] = ind2sub(size(D), im);
    b0 = [cosd(elg(ie))*cosd(azg(ia)), cosd(elg(ie))*sind(azg(ia)), sind(elg(ie))];
    E = EHfields(ant, f0, 100 * (299792458/f0) * b0(:));
    [~, ix] = max(abs(E));  E = E * exp(-1i * angle(E(ix)));
    e0 = real(E(:)).';  e0 = e0 - dot(e0, b0) * b0;  e0 = e0 / norm(e0);
    % wanted: beam b and element direction e in East-North-Up
    U = [0 0 1];  bH = [sind(bAz), cosd(bAz), 0];  hz = [sind(bAz + 90), cosd(bAz + 90), 0];
    if any(strcmp(A.model, {'dipole', 'dipoleFolded'}))           % omni dipole: broadside towards bAz
        b = bH;
        if upper(A.pol(1)) == 'V', e = U; else, e = hz; end
    else
        b = [cosd(bEl)*sind(bAz), cosd(bEl)*cosd(bAz), sind(bEl)];
        if abs(b(3)) > 0.999, eH = hz; else, eH = cross(U, b);  eH = eH / norm(eH); end
        if upper(A.pol(1)) == 'V', e = cross(b, eH);  e = e / norm(e); else, e = eH; end
    end
    Rm = [b(:) e(:) cross(b, e)'] * [b0(:) e0(:) cross(b0, e0)']';
    Rt = Rm * tiltMatrix(ant.Tilt, ant.TiltAxis);                % compose with the design's own tilt
    ang = acosd(max(-1, min(1, (trace(Rt) - 1) / 2)));
    if ang < 1e-6
        ant.Tilt = 0;  ant.TiltAxis = [0 0 1];
    else
        if abs(ang - 180) < 1e-3
            [V, Dg] = eig(Rt);  [~, j] = min(abs(diag(Dg) - 1));  ax = real(V(:,j)).';
        else
            ax = [Rt(3,2) - Rt(2,3), Rt(1,3) - Rt(3,1), Rt(2,1) - Rt(1,2)];
        end
        ant.Tilt = ang;  ant.TiltAxis = ax / norm(ax);
    end
end

function R = tiltMatrix(tilt, axisIn)
% Rotation matrix of an Antenna Toolbox Tilt / TiltAxis setting (rotations applied in order).
    R = eye(3);
    if isempty(tilt), return; end
    for i = 1:numel(tilt)
        if ischar(axisIn) || isstring(axisIn)
            ax = char(axisIn);  if size(ax, 1) > 1, ax = ax(i,:); end
            v = double([strcmpi(strtrim(ax), 'x'), strcmpi(strtrim(ax), 'y'), strcmpi(strtrim(ax), 'z')]);
        else
            v = axisIn(min(i, size(axisIn, 1)), :);
        end
        if norm(v) == 0, continue; end
        v = v / norm(v);  K = [0 -v(3) v(2); v(3) 0 -v(1); -v(2) v(1) 0];
        Ri = eye(3) + sind(tilt(i)) * K + (1 - cosd(tilt(i))) * K^2;
        R = Ri * R;
    end
end

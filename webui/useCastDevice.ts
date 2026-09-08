// Copyright (C) 2017-2026 Smart code 203358507

import { useCallback, useEffect, useRef, useState } from 'react';

// Playing on a DLNA renderer is fire and forget in the player: PlayOnDevice is
// dispatched, the local video is paused, and nothing after that reaches the TV.
// Chromecast has a whole transport for this; a TV has none. This hook is that
// transport, spoken over the streaming server's own casting endpoint.

export type CastState = {
    paused: boolean | null,
    time: number | null,
    duration: number | null,
    volume: number | null,
    subtitlesSrc: string | null,
    subtitlesDelay: number | null,
};

const EMPTY: CastState = {
    paused: null, time: null, duration: null,
    volume: null, subtitlesSrc: null, subtitlesDelay: null,
};

const POLL_MS = 2000;
// A change restarts the transcode on the server, and the renderer needs a moment
// to pick the new stream up. Until then its answers describe the old one, so we
// show what was asked for rather than letting the display jump back.
const SETTLE_MS = 8000;

const useCastDevice = (baseUrl: string | null, deviceId: string | null) => {
    const [state, setState] = useState<CastState>(EMPTY);
    const pending = useRef<{ time?: number, paused?: boolean, until: number } | null>(null);
    const active = baseUrl !== null && deviceId !== null;

    const endpoint = useCallback((query?: Record<string, string | number>) => {
        const root = String(baseUrl).replace(/\/+$/, '');
        const q = query ? '?' + new URLSearchParams(
            Object.entries(query).map(([k, v]) => [k, String(v)])
        ).toString() : '';
        return `${root}/casting/${deviceId}/player${q}`;
    }, [baseUrl, deviceId]);

    const command = useCallback((query: Record<string, string | number>) => {
        if (!active) return;
        fetch(endpoint(query), { method: 'POST' }).catch(() => null);
    }, [active, endpoint]);

    useEffect(() => {
        if (!active) {
            setState(EMPTY);
            pending.current = null;
            return;
        }
        let stopped = false;
        let timer: ReturnType<typeof setTimeout>;
        const tick = () => {
            fetch(endpoint())
                .then((r) => r.json())
                .then((d) => {
                    if (stopped || !d || typeof d !== 'object') return;
                    const held = pending.current;
                    const holding = held !== null && Date.now() < held.until;
                    if (held !== null && !holding) pending.current = null;
                    setState({
                        paused: holding && typeof held?.paused === 'boolean'
                            ? held.paused
                            : typeof d.paused === 'boolean' ? d.paused : null,
                        time: holding && typeof held?.time === 'number'
                            ? held.time
                            : typeof d.time === 'number' ? d.time : null,
                        duration: typeof d.length === 'number' && d.length > 0 ? d.length : null,
                        volume: typeof d.volume === 'number' ? Math.round(d.volume * 100) : null,
                        subtitlesSrc: typeof d.subtitlesSrc === 'string' ? d.subtitlesSrc : null,
                        subtitlesDelay: typeof d.subtitlesDelay === 'number' ? d.subtitlesDelay : null,
                    });
                })
                .catch(() => null)
                .then(() => {
                    if (!stopped) timer = setTimeout(tick, POLL_MS);
                });
        };
        tick();
        return () => { stopped = true; clearTimeout(timer); };
    }, [active, endpoint]);

    const hold = (patch: { time?: number, paused?: boolean }) => {
        pending.current = { ...(pending.current || {}), ...patch, until: Date.now() + SETTLE_MS };
        setState((s) => ({ ...s, ...patch }));
    };

    const play = useCallback(() => { hold({ paused: false }); command({ paused: 0 }); }, [command]);
    const pause = useCallback(() => { hold({ paused: true }); command({ paused: 1 }); }, [command]);
    const seek = useCallback((time: number) => {
        const t = Math.max(0, Math.round(time));
        hold({ time: t, paused: false });
        command({ time: t });
    }, [command]);
    const setVolume = useCallback((volume: number) => {
        command({ volume: Math.max(0, Math.min(100, Math.round(volume))) / 100 });
    }, [command]);
    const setSubtitles = useCallback((url: string | null) => {
        command({ subtitlesSrc: url === null ? '' : url });
    }, [command]);
    const setSubtitlesDelay = useCallback((delay: number) => {
        command({ subtitlesDelay: Math.round(delay) });
    }, [command]);
    const stop = useCallback(() => { command({ stop: 1 }); }, [command]);

    return { active, state, play, pause, seek, setVolume, setSubtitles, setSubtitlesDelay, stop };
};

export default useCastDevice;

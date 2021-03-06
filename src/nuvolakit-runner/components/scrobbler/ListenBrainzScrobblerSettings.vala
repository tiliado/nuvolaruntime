/*
 * Copyright 2014-2020 Jiří Janoušek <janousek.jiri@gmail.com>
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are met:
 *
 * 1. Redistributions of source code must retain the above copyright notice, this
 *    list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright notice,
 *    this list of conditions and the following disclaimer in the documentation
 *    and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
 * ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 * WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 * DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR
 * ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 * (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
 * LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
 * ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
 * SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

namespace Nuvola {

public class ListenBrainzScrobblerSettings: Gtk.Grid {
    private ListenBrainzScrobbler scrobbler;
    private unowned Drtgtk.Application app;
    private Gtk.Switch checkbox;
    private Gtk.Entry? token_entry;

    public ListenBrainzScrobblerSettings(ListenBrainzScrobbler scrobbler, Drtgtk.Application app) {
        Object(orientation: Gtk.Orientation.VERTICAL, column_spacing: 10, row_spacing: 10);
        this.scrobbler = scrobbler;
        this.app = app;
        hexpand = true;

        var row = 2;
        checkbox = new Gtk.Switch();
        checkbox.vexpand = checkbox.hexpand = false;
        checkbox.halign = checkbox.valign = Gtk.Align.CENTER;
        attach(checkbox, 0, row, 1, 1);
        var label = new Gtk.Label("Scrobble played tracks");
        label.vexpand = false;
        label.hexpand = true;
        label.halign = Gtk.Align.START;
        attach(label, 1, row, 1, 1);

        if (!scrobbler.has_session) {
            add_info_bar(
                "You have not connected your account yet.", "Connect", Gtk.MessageType.WARNING, 1);
            checkbox.sensitive = false;
            checkbox.active = false;
        } else {
            add_info_bar(
                "Connected account: %s".printf(scrobbler.username ?? "(unknown)"),
                "Disconnect", Gtk.MessageType.OTHER, 3);
            toggle_switches(true);
        }
    }

    private void toggle_switches(bool enabled) {
        if (enabled) {
            checkbox.active = scrobbler.scrobbling_enabled;
            checkbox.sensitive = true;
            scrobbler.notify.connect_after(on_notify);
            checkbox.notify.connect_after(on_notify);
        } else {
            scrobbler.notify.disconnect(on_notify);
            checkbox.notify.disconnect(on_notify);
            checkbox.active = false;
            checkbox.sensitive = false;
        }
    }

    private void add_info_bar(string text, string button_label, Gtk.MessageType type, int response_id) {
        var info_bar = new Gtk.InfoBar.with_buttons(button_label, response_id, null);
        info_bar.message_type = type;
        var label = new Gtk.Label(text);
        label.set_line_wrap(true);
        info_bar.get_content_area().add(label);
        info_bar.response.connect(on_response);
        info_bar.show_all();
        attach(info_bar, 0, 0, 2, 1);
    }

    private void on_notify(GLib.Object o, ParamSpec p) {
        switch (p.name) {
        case "scrobbling-enabled":
            if (checkbox.active != scrobbler.scrobbling_enabled) {
                checkbox.active = scrobbler.scrobbling_enabled;
            }
            break;
        case "active":
            if (scrobbler.scrobbling_enabled != checkbox.active) {
                scrobbler.scrobbling_enabled = checkbox.active;
            }
            break;
        }
    }

    private void remove_info_bars() {
        foreach (Gtk.Widget child in get_children()) {
            if (child is Gtk.InfoBar) {
                remove(child);
            }
        }
    }

    private void on_response(GLib.Object emitter, int response_id) {
        var info_bar = emitter as Gtk.InfoBar;
        switch (response_id) {
        case 1:
            info_bar.sensitive = false;
            request_token();

            break;
        case 2:
            string token = token_entry.text;
            token_entry = null;

            if (Drt.String.is_empty(token)) {
                remove_info_bars();
                add_info_bar("Token must not be empty.", "Retry", Gtk.MessageType.ERROR, 1);
            } else {
                info_bar.sensitive = false;
                scrobbler.set_token.begin(token, on_set_token_done);
            }
            break;
        case 3:
            scrobbler.drop_session();
            remove_info_bars();
            add_info_bar(
                "Your account has been disconnected.", "Connect", Gtk.MessageType.INFO, 1);
            toggle_switches(false);
            break;
        }
    }

    private void request_token() {
        remove_info_bars();

        var info_bar = new Gtk.InfoBar.with_buttons("Connect", 2, null);
        info_bar.message_type = Gtk.MessageType.INFO;

        var label = new Gtk.Label(
            "User token from <a href=\"https://listenbrainz.org/profile/\"> your profile</a>:");
        label.use_markup = true;
        label.set_line_wrap(true);
        info_bar.get_content_area().add(label);

        token_entry = new Gtk.Entry();
        info_bar.get_content_area().add(token_entry);
        info_bar.response.connect(on_response);
        info_bar.show_all();
        attach(info_bar, 0, 1, 2, 1);
    }

    private void on_set_token_done(GLib.Object? o, AsyncResult res) {
        try {
            remove_info_bars();
            scrobbler.set_token.end(res);
            toggle_switches(true);
            add_info_bar(
                "You have connected account: %s".printf(scrobbler.username ?? "(unknown)"),
                "Disconnect", Gtk.MessageType.INFO, 3);
        } catch (AudioScrobblerError e) {
            string msg = (e is AudioScrobblerError.NOT_AUTHENTICATED)
            ? "Token is invalid." : "Failed to validate token.";
            warning("Failed to validate token: %s", e.message);
            add_info_bar(msg, "Retry", Gtk.MessageType.ERROR, 1);
        }
    }
}

} // namespace Nuvola

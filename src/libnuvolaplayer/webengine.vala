/*
 * Copyright 2014 Jiří Janoušek <janousek.jiri@gmail.com>
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

using Nuvola.JSTools;

namespace Nuvola
{

private extern const string WEBKIT_EXTENSION_DIR;

public class WebEngine : GLib.Object
{
	public Gtk.Widget widget {get {return web_view;}}
	public WebApp web_app {get; private set;}
	private WebAppController app;
	private WebKit.WebView web_view;
	private JsEnvironment? env = null;
	private JSApi api;
	private Diorite.Ipc.MessageServer master = null;
	private Diorite.Ipc.MessageClient slave = null;
	private static const string MASTER_SUFFIX = ".master";
	private static const string SLAVE_SUFFIX = ".slave";
	private string[] app_errors;
	private Variant[] received_messages;
	private Config config;
	
	public WebEngine(WebAppController app, WebApp web_app, Config config)
	{
		var webkit_extension_dir = Environment.get_variable("NUVOLA_WEBKIT_EXTENSION_DIR") ?? WEBKIT_EXTENSION_DIR;
		Environment.set_variable("NUVOLA_IPC_MASTER", app.path_name + MASTER_SUFFIX, true);
		Environment.set_variable("NUVOLA_IPC_SLAVE", app.path_name + SLAVE_SUFFIX, true);
		debug("Nuvola WebKit Extension directory: %s", webkit_extension_dir);
		
		var wc = WebKit.WebContext.get_default();
		wc.set_web_extensions_directory(webkit_extension_dir);
		wc.set_cache_model(WebKit.CacheModel.DOCUMENT_VIEWER);
		wc.set_favicon_database_directory(web_app.user_data_dir.get_child("favicons").get_path());
		wc.set_disk_cache_directory(web_app.user_cache_dir.get_child("webcache").get_path());
		
		var cm = wc.get_cookie_manager();
		cm.set_persistent_storage(web_app.user_data_dir.get_child("cookies.dat").get_path(), WebKit.CookiePersistentStorage.SQLITE);
		
		this.app = app;
		this.web_app = web_app;
		this.config = config;
		this.web_view = new WebKit.WebView();
		var ws = web_view.get_settings();
		ws.enable_developer_extras = true;
		ws.enable_java = false;
		ws.enable_page_cache = false;
		ws.enable_smooth_scrolling = true;
		ws.enable_write_console_messages_to_stdout = true;
		app_errors = {};
		received_messages = {};
		web_view.decide_policy.connect(on_decide_policy);
	}
	
	public virtual signal void message_received(string name, Variant? data)
	{
		debug("Message received from JSApi: %s:%s", name, data == null ? "null" : data.get_type_string());
	}
	
	private bool inject_api()
	{
		if (env != null)
			return true;
		
		env = new JsRuntime();
		api = new JSApi(app.storage, web_app.data_dir, web_app.user_config_dir, config);
		api.send_message.connect(on_send_message);
		try
		{
			api.inject(env);
			api.initialize(env);
		}
		catch (JSError e)
		{
			app.fatal_error("Initialization error", e.message);
			return false;
		}
		return true;
	}
	
	private string? data_request(string name, string key, string? default_value=null) throws JSError
	{
		string? result = null;
		var builder = new VariantBuilder(new VariantType("a{smv}"));
		builder.add("{smv}", key, default_value == null ? null : new Variant.string(default_value));
		var args = new Variant("(s@a{smv})", name, builder.end());
		env.call_function("emit", ref args);
		VariantIter iter = args.iterator();
		assert(iter.next("s", null));
		assert(iter.next("a{smv}", &iter));
		string dict_key = null;
		Variant value = null;
		while (iter.next("{smv}", &dict_key, &value))
			if (dict_key == key)
				result = value != null ? value.get_string() : null;
		
		if(result == "")
			result = null;
		return result;
	}
	
	
	private bool load_uri(string uri)
	{
		if (uri.has_prefix("http://") || uri.has_prefix("https://"))
		{
			web_view.load_uri(uri);
			return true;
		}
		
		if(uri.has_prefix("nuvola://"))
		{
			web_view.load_uri(web_app.data_dir.get_child(uri.substring(9)).get_uri());
			return true;
		}
		
		return false;
	}
	
	public bool load()
	{
		if (!inject_api())
			return false;
		
		start_master();
		
		return go_home();
	}
	
	public bool go_home()
	{
		try
		{
			var url = data_request("home-page", "url");
			if (url == null)
				app.show_error("Invalid home page URL", "The web app integration script has an empty home page URL.");
			else if (!load_uri(url))
				app.show_error("Invalid home page URL", "The web app integration script has not provided a valid home page URL '%s'.".printf(url));
		}
		catch (JSError e)
		{
			app.fatal_error("Initialization error", "%s failed to retrieve a home page of  a web app. Initialization exited with error:\n\n%s".printf(app.app_name, e.message));
			return false;
		}
		
		return true;
	}
	
	public void call_function(string name, Variant? params) throws Diorite.Ipc.MessageError
	{
		assert(slave != null);
		var data = new Variant("(smv)", name, params);
		slave.send_message("call_function", data);
	}
	
	public void message_handled()
	{
		Signal.stop_emission_by_name(this, "message-received");
	}
	
	private void start_master()
	{
		if (master != null)
			return;
		
		master = new Diorite.Ipc.MessageServer(app.path_name + MASTER_SUFFIX);
		master.add_handler("get_data_dir", this, (Diorite.Ipc.MessageHandler) WebEngine.handle_get_data_dir);
		master.add_handler("get_user_config_dir", this, (Diorite.Ipc.MessageHandler) WebEngine.handle_get_user_config_dir);
		master.add_handler("show_error", this, (Diorite.Ipc.MessageHandler) WebEngine.handle_show_error);
		master.add_handler("send_message", this, (Diorite.Ipc.MessageHandler) WebEngine.handle_send_message);
		new Thread<void*>(app.path_name, listen);
		slave = new Diorite.Ipc.MessageClient(app.path_name + SLAVE_SUFFIX, 5000);
	}
	
	private void* listen()
	{
		try
		{
			master.listen();
		}
		catch (Diorite.IOError e)
		{
			warning("Master server error: %s", e.message);
		}
		return null;
	}
	
	private bool handle_get_data_dir(Diorite.Ipc.MessageServer server, Variant request, out Variant? response)
	{
		response = new Variant.string(web_app.data_dir.get_path());
		return true;
	}
	
	private bool handle_get_user_config_dir(Diorite.Ipc.MessageServer server, Variant request, out Variant? response)
	{
		response = new Variant.string(web_app.user_config_dir.get_path());
		return true;
	}
	
	private bool handle_show_error(Diorite.Ipc.MessageServer server, Variant request, out Variant? response)
	{
		response = null;
		lock (app_errors)
		{
			app_errors += request.get_string();
		}
		Idle.add(show_app_errors_cb);
		return true;
	}
	
	private bool show_app_errors_cb()
	{
		lock (app_errors)
		{
			foreach (var message in app_errors)
				app.show_error("Integration error", message);
			app_errors = {};
		}
		return false;
	}
	
	private bool handle_send_message(Diorite.Ipc.MessageServer server, Variant request, out Variant? response)
	{
		response = null;
		lock (received_messages)
		{
			received_messages += request;
		}
		Idle.add(message_received_cb);
		return true;
	}
	
	private bool message_received_cb()
	{
		lock (received_messages)
		{
			foreach (var message in received_messages)
			{
				string name = null;
				Variant? data = null;
				message.get("(smv)", &name, &data);
				message_received(name, data);
			}
			received_messages = {};
		}
		return false;
	}
	
	private void on_send_message(string name, Variant? data)
	{
		message_received(name, data);
	}
	
	private bool on_decide_policy(WebKit.PolicyDecision decision, WebKit.PolicyDecisionType decision_type)
	{
		switch (decision_type)
		{
		case WebKit.PolicyDecisionType.NAVIGATION_ACTION:
			WebKit.NavigationPolicyDecision navigation_decision = (WebKit.NavigationPolicyDecision) decision;
			if (navigation_decision.mouse_button == 0)
				return false;
			var uri = navigation_decision.request.uri;
			if (!uri.has_prefix("http://") && !uri.has_prefix("https://"))
				return false;
			var result = navigation_request(uri);
			debug("Mouse Navigation: %s %s", uri, result.to_string());
			if (result)
			{
				decision.use();
				return true;
			}
			else
			{
				try
				{
					Gtk.show_uri(null, uri, Gdk.CURRENT_TIME);
					decision.ignore();
					return true;
				}
				catch (GLib.Error e)
				{
					critical("Failed to open '%s' in a default web browser. %s", uri, e.message);
					return false;
				}
			}
		case WebKit.PolicyDecisionType.NEW_WINDOW_ACTION:
		case WebKit.PolicyDecisionType.RESPONSE:
		default:
			return false;
		}
	}
	
	private bool navigation_request(string url)
	{
		var builder = new VariantBuilder(new VariantType("a{smv}"));
		builder.add("{smv}", "url", new Variant.string(url));
		builder.add("{smv}", "approved", new Variant.boolean(true));
		var args = new Variant("(s@a{smv})", "navigation-request", builder.end());
		try
		{
			env.call_function("emit", ref args);
		}
		catch (JSError e)
		{
			app.show_error("Integration script error", "The web app integration script has not provided a valid response and caused an error: %s".printf(e.message));
			return true;
		}
		VariantIter iter = args.iterator();
		assert(iter.next("s", null));
		assert(iter.next("a{smv}", &iter));
		string key = null;
		Variant value = null;
		bool approved = false;
		while (iter.next("{smv}", &key, &value))
			if (key == "approved")
				approved = value != null ? value.get_boolean() : false;
		
		return approved;
	}
}

} // namespace Nuvola

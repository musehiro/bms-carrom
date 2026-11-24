/**************************************************************************/
/*  GodotApp.java                                                         */
/**************************************************************************/
/*                         This file is part of:                          */
/*                             GODOT ENGINE                               */
/*                        https://godotengine.org                         */
/**************************************************************************/
/* Copyright (c) 2014-present Godot Engine contributors (see AUTHORS.md). */
/* Copyright (c) 2007-2014 Juan Linietsky, Ariel Manzur.                  */
/*                                                                        */
/* Permission is hereby granted, free of charge, to any person obtaining  */
/* a copy of this software and associated documentation files (the        */
/* "Software"), to deal in the Software without restriction, including    */
/* without limitation the rights to use, copy, modify, merge, publish,    */
/* distribute, sublicense, and/or sell copies of the Software, and to     */
/* permit persons to whom the Software is furnished to do so, subject to  */
/* the following conditions:                                              */
/*                                                                        */
/* The above copyright notice and this permission notice shall be         */
/* included in all copies or substantial portions of the Software.        */
/*                                                                        */
/* THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,        */
/* EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF     */
/* MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. */
/* IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY   */
/* CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,   */
/* TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE      */
/* SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.                 */
/**************************************************************************/

package com.godot.game;

import org.godotengine.godot.GodotActivity;

import android.content.Intent;
import android.net.Uri;
import android.os.Bundle;
import android.util.Log;

import androidx.core.splashscreen.SplashScreen;

import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.nio.charset.StandardCharsets;

/**
 * Template activity for Godot Android builds.
 * Feel free to extend and modify this class for your custom logic.
 *
 * Auth return path (v9, restored v11): Supabase redirects the browser to
 * com.musehiro.carrom://auth-callback?code=... after Google sign-in or an
 * OTP magic-link tap. The intent filter for that scheme lives in the
 * Gradle main manifest (android/build/AndroidManifest.xml). Vanilla
 * Godot 4.3 does not surface deep links to GDScript, so this activity
 * captures the incoming URI and writes it to auth_callback.txt in the
 * app's internal files dir — the same directory Godot maps user:// to
 * on Android — where scripts/accounts.gd polls for it
 * (Supabase.AUTH_CALLBACK_FILE = "user://auth_callback.txt") while a
 * sign-in is pending. Handles all three arrival shapes: a cold start
 * with the deep link (onCreate), a return to the running activity
 * (onNewIntent — the activity is singleInstancePerTask), and a resume
 * where the intent was delivered but the write never happened
 * (onResume, guarded so an already-consumed URI is never rewritten).
 */
public class GodotApp extends GodotActivity {
	private static final String TAG = "BMSCarromAuth";
	private static final String AUTH_SCHEME = "com.musehiro.carrom";
	private static final String AUTH_HOST = "auth-callback";
	private static final String AUTH_CALLBACK_FILE = "auth_callback.txt";

	@Override
	public void onCreate(Bundle savedInstanceState) {
		SplashScreen.installSplashScreen(this);
		super.onCreate(savedInstanceState);
		handleDeepLink(getIntent());
	}

	@Override
	protected void onNewIntent(Intent intent) {
		super.onNewIntent(intent);
		setIntent(intent);
		handleDeepLink(intent);
	}

	@Override
	protected void onResume() {
		super.onResume();
		handleDeepLink(getIntent());
	}

	/**
	 * Write the auth-callback URI to auth_callback.txt when the intent
	 * carries one. No-op for any other intent (launcher starts, etc.).
	 * Skips the write when the file already holds the same URI, so a
	 * resume never resurrects a URI the game already consumed.
	 */
	private void handleDeepLink(Intent intent) {
		if (intent == null) {
			return;
		}
		Uri data = intent.getData();
		if (data == null) {
			return;
		}
		if (!AUTH_SCHEME.equals(data.getScheme()) || !AUTH_HOST.equals(data.getHost())) {
			return;
		}
		String uri = data.toString();
		File out = new File(getFilesDir(), AUTH_CALLBACK_FILE);
		try {
			if (out.exists()) {
				String existing = readFile(out);
				if (uri.equals(existing)) {
					return;
				}
			}
			try (FileOutputStream fos = new FileOutputStream(out, false)) {
				fos.write(uri.getBytes(StandardCharsets.UTF_8));
			}
			Log.i(TAG, "Wrote auth callback URI to " + AUTH_CALLBACK_FILE);
		} catch (IOException e) {
			Log.w(TAG, "Failed to write " + AUTH_CALLBACK_FILE, e);
		}
	}

	private static String readFile(File file) throws IOException {
		try (FileInputStream fis = new FileInputStream(file)) {
			byte[] bytes = new byte[(int) file.length()];
			int read = fis.read(bytes);
			if (read < 0) {
				return "";
			}
			return new String(bytes, 0, read, StandardCharsets.UTF_8);
		}
	}
}

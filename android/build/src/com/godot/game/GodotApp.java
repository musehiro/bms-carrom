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

import androidx.core.splashscreen.SplashScreen;

import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.nio.charset.StandardCharsets;

/**
 * Template activity for Godot Android builds.
 * Feel free to extend and modify this class for your custom logic.
 *
 * BMS Carrom (v9): deep-link bridge for Google sign-in. Vanilla Godot
 * 4.3 does not surface Android deep-link URIs to GDScript, so when the
 * browser returns to com.musehiro.carrom://auth-callback?code=... the
 * URI is written to user://auth_callback.txt (getFilesDir() is the
 * same directory Godot maps user:// to) and the game polls for it
 * while a Google sign-in is pending (see scripts/accounts.gd).
 */
public class GodotApp extends GodotActivity {
	@Override
	public void onCreate(Bundle savedInstanceState) {
		SplashScreen.installSplashScreen(this);
		super.onCreate(savedInstanceState);
		_forwardDeepLink(getIntent());
	}

	@Override
	protected void onNewIntent(Intent intent) {
		super.onNewIntent(intent);
		_forwardDeepLink(intent);
	}

	private void _forwardDeepLink(Intent intent) {
		if (intent == null) {
			return;
		}
		Uri data = intent.getData();
		if (data == null) {
			return;
		}
		String uri = data.toString();
		if (uri == null || !uri.startsWith("com.musehiro.carrom://")) {
			return;
		}
		try {
			File out = new File(getFilesDir(), "auth_callback.txt");
			FileOutputStream stream = new FileOutputStream(out, false);
			try {
				stream.write(uri.getBytes(StandardCharsets.UTF_8));
			} finally {
				stream.close();
			}
		} catch (IOException e) {
			// Nothing to do here — the loopback listener is the fallback.
		}
	}
}

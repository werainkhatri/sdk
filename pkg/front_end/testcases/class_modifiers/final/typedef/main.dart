// Copyright (c) 2023, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'main_lib.dart';

class ExtendsFinalClassTypedef extends ATypeDef {}

class ExtendsFinalClassTypedef2 extends ATypeDef2 {}

class ImplementsFinalClassTypedef implements ATypeDef {}

class ImplementsFinalClassTypedef2 implements ATypeDef2 {}

enum EnumImplementsFinalClassTypedef implements ATypeDef { x }

enum EnumImplementsFinalClassTypedef2 implements ATypeDef2 { x }

class ImplementsFinalMixinTypeDef implements MTypeDef {}

class ImplementsFinalMixinTypeDef2 implements MTypeDef2 {}

enum EnumImplementsFinalMixinTypeDef implements MTypeDef { x }

enum EnumImplementsFinalMixinTypeDef2 implements MTypeDef2 { x }

class MixInFinalMixinTypeDef with MTypeDef {}

class MixInFinalMixinTypeDef2 with MTypeDef2 {}

enum EnumMixInFinalMixinTypeDef with MTypeDef { x }

enum EnumMixInFinalMixinTypeDef2 with MTypeDef2 { x }

typedef AOutsideTypedef = A;

typedef MOutsideTypedef = M;

class ExtendsFinalClassTypedefOutside extends AOutsideTypedef {}

class ImplementsFinalClassTypedefOutside implements AOutsideTypedef {}

enum EnumImplementsFinalClassTypedefOutside implements AOutsideTypedef { x }

class ImplementsFinalMixinTypeDefOutside implements MOutsideTypedef {}

enum EnumImplementsFinalMixinTypeDefOutside implements MOutsideTypedef { x }

class MixInFinalMixinTypeDefOutside with MOutsideTypedef {}

enum EnumMixInFinalMixinTypeDefOutside with MOutsideTypedef { x }

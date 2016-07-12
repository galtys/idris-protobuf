||| Copyright 2016 Google Inc.
|||
||| Licensed under the Apache License, Version 2.0 (the "License");
||| you may not use this file except in compliance with the License.
||| You may obtain a copy of the License at
|||
|||     http://www.apache.org/licenses/LICENSE-2.0
|||
||| Unless required by applicable law or agreed to in writing, software
||| distributed under the License is distributed on an "AS IS" BASIS,
||| WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
||| See the License for the specific language governing permissions and
||| limitations under the License.

module Protobuf.Deserializer

import Protobuf.Core

%default total

-- Export as public since text and wire format code must be able to construct
-- implementations.


public export data DeserializationError : Type where
  NoEnumValueWithName : String -> DeserializationError
  NoEnumValueWithNumber : Int -> DeserializationError
  NoFieldWithName : String -> DeserializationError
  NoFieldWithNumber : Int -> DeserializationError
  NoValueForRequiredField : String -> DeserializationError

-- For convenience, provide an implementation of Show DeserializationError.

export implementation Show DeserializationError where
  show (NoEnumValueWithName name) = "There was no enum value with name " ++ (show name)
  show (NoEnumValueWithNumber number) = "There was no enum value with number " ++ (show number)
  show (NoFieldWithName name) = "There was no field with name " ++ (show name)
  show (NoFieldWithNumber number) = "There was no field with number " ++ (show number)
  show (NoValueForRequiredField name) = "The required field " ++ (show name) ++ " was not set"

||| The interface for a deserializer that deserializes protocol buffers from
||| some format.
public export interface Monad m => Deserializer (m : Type -> Type) where
  ||| Starts reading a field, returning either the name of number of the field.
  readFieldNameOrNumber : m (Either String Int)

  deserializeDouble : m Double
  deserializeFloat : m Double
  deserializeInt32 : m Integer
  deserializeInt64 : m Integer
  deserializeUInt32 : m Integer
  deserializeUInt64 : m Integer
  deserializeSInt32 : m Integer
  deserializeSInt64 : m Integer
  deserializeFixed32 : m Integer
  deserializeFixed64 : m Integer
  deserializeSFixed32 : m Integer
  deserializeSFixed64 : m Integer
  deserializeBool : m Bool
  deserializeString : m String
  deserializeBytes : m String
  readEnumValueNameOrNumber : m (Either String Int)
  ||| Start decoding a message.
  startMessage : m ()
  ||| Returns true when the last message of a field has been read.
  isEndMessage : m Bool

  ||| Emits an error, and returns this error wrapped as `m a` for the given type
  ||| `a`.  This allows errors generated by the high level deserialization logic
  ||| to be incorporated into the parsers internal error generation.  E.g. it
  ||| may attach appropriate start-end cursors to the error in text format.
  error : DeserializationError -> m a


singularTypeForField : FieldDescriptor -> Type
singularTypeForField (MkFieldDescriptor _ ty _ _) = interpFieldValue ty

-- Because fields can come in any order, parsing a message is done in two
-- phases.  First, we parse all the fields into a list of pairs
-- (i : Fin k ** interpField (index fields i))
-- Second, for each field we scan through this list and fill in that field's
-- value based on the list (or create an error).
FieldList : Vect k FieldDescriptor -> Type
FieldList {k=k} fields = List (i : Fin k ** singularTypeForField (index i fields))

||| Takes a `FieldList`, and selects the elements which represent the 0th field
||| and puts these into a list, and also creates a list of the remaining
||| elements, which are mapped to be part of of a new `FieldList` for the
||| remaining fields.
reduceFieldList : FieldList (f :: fs) -> (List (singularTypeForField f), FieldList fs)
reduceFieldList Nil = (Nil, Nil)
reduceFieldList ((FZ ** x) :: xs) = let (ys, zs) = reduceFieldList xs in
  (x :: ys, zs)
reduceFieldList (((FS k) ** x) :: xs) = let (ys, zs) = reduceFieldList xs in
  (ys, (k ** x) :: zs)

optionalFieldFromList : List (interpFieldValue f) -> Maybe (interpFieldValue f)
optionalFieldFromList Nil      = Nothing
optionalFieldFromList (x::Nil) = Just x
optionalFieldFromList (x::xs)  = optionalFieldFromList xs

fieldFromFieldList : Deserializer m => List (singularTypeForField d) -> m (interpField d)
fieldFromFieldList {d=MkFieldDescriptor Optional _ _ _} xs = return (optionalFieldFromList xs)
fieldFromFieldList {d=MkFieldDescriptor Required _ name _} xs = case (optionalFieldFromList xs) of
    Nothing  => error (NoValueForRequiredField name)
    (Just x) => return x
fieldFromFieldList {d=MkFieldDescriptor Repeated _ _ _} xs = return xs

messageFromFieldList : Deserializer m => FieldList fields -> m (InterpFields fields)
messageFromFieldList {fields=Nil} _ = return Nil
messageFromFieldList {fields=f::fs} xs = let (ys, zs) = reduceFieldList xs in do {
  first <- fieldFromFieldList ys
  rest <- messageFromFieldList zs
  return (first :: rest)
}

mutual
  partial deserializeMessage' : Deserializer m => m (InterpMessage d)
  deserializeMessage' {d=MkMessageDescriptor fs} = do {
    xs <- deserializeFields
    fields <- messageFromFieldList xs
    return (MkMessage fields)
  }

  partial deserializeFields : Deserializer m => m (FieldList d)
  deserializeFields {d=d} = do {
    endMessage <- isEndMessage
    if endMessage then
      return Nil
    else do {
      fieldNameOrNumber <- readFieldNameOrNumber
      -- TODO: Make this less redundant.
      case fieldNameOrNumber of
        Left name' => case (findIndex (\f => name f == name') d) of
          Nothing => error (NoFieldWithName name')
          Just i => do {
            v <- deserializeField {d=index i d}
            rest <- deserializeFields {d=d}
            return ((i ** v) :: rest)
          }
        Right number' => case (findIndex (\f => number f == number') d) of
          Nothing => error (NoFieldWithNumber number')
          Just i => do {
            v <- deserializeField {d=index i d}
            rest <- deserializeFields {d=d}
            return ((i ** v) :: rest)
          }
    }
  }

  partial deserializeField : Deserializer m => m (singularTypeForField d)
  deserializeField {d=MkFieldDescriptor _ ty _ _} = deserializeFieldValue {d=ty}

  partial deserializeFieldValue : Deserializer m => m (interpFieldValue d)
  deserializeFieldValue {d=PBDouble} = deserializeDouble
  deserializeFieldValue {d=PBFloat} = deserializeFloat
  deserializeFieldValue {d=PBInt32} = deserializeInt32
  deserializeFieldValue {d=PBInt64} = deserializeInt64
  deserializeFieldValue {d=PBUInt32} = deserializeUInt32
  deserializeFieldValue {d=PBUInt64} = deserializeUInt64
  deserializeFieldValue {d=PBSInt32} = deserializeSInt32
  deserializeFieldValue {d=PBSInt64} = deserializeSInt64
  deserializeFieldValue {d=PBFixed32} = deserializeFixed32
  deserializeFieldValue {d=PBFixed64} = deserializeFixed64
  deserializeFieldValue {d=PBSFixed32} = deserializeSFixed32
  deserializeFieldValue {d=PBSFixed64} = deserializeSFixed64
  deserializeFieldValue {d=PBBool} = deserializeBool
  deserializeFieldValue {d=PBString} = deserializeString
  deserializeFieldValue {d=PBBytes} = deserializeBytes
  deserializeFieldValue {d=PBEnum (MkEnumDescriptor values)} = do {
    enumValueNameOrNumber <- readEnumValueNameOrNumber
    case enumValueNameOrNumber of
    Left name' => case (findIndex (\v => name v == name') values) of
      Nothing => error (NoEnumValueWithName name')
      Just i => return i
    Right number' => case (findIndex (\v => number v == number') values) of
      Nothing => error (NoEnumValueWithNumber number')
      Just i => return i
  }
  deserializeFieldValue {d=PBMessage msg} = do {
    startMessage
    deserializeMessage' {d=msg}
  }

export deserializeMessage : Deserializer m => m (InterpMessage d)
deserializeMessage {d=d} = assert_total (deserializeMessage' {d=d})

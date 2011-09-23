module Broadcast where

import Control.Concurrent.STM
import Data.Map as M
import Debug.Trace
import System.IO

import Message

-- This module is responsible for broadcasting messages
-- to the proper users.

data Room = Room {
  roomName :: String,
  users :: [User]
} deriving (Show, Eq)

data User = User {
  userName :: String,
  handle :: Handle,
  rooms :: [Room]
} deriving (Show, Eq)

makeUser name handle = User { userName = name, handle = handle, rooms = [] }
makeRoom name = Room { roomName = name, users = [] }

type UserStore = TVar (Map String (TVar User))
type RoomStore = TVar (Map String (TVar Room))

sendMessage :: User -> ClientMessage -> IO ()
sendMessage to msg = do
  let hdl = handle to
  hPutStr hdl ((show msg) ++ "\r\n")
  return ()
  
handlerThread :: UserStore -> 
                 RoomStore -> 
                 TChan (Handle, ServerMessage) ->
                 TChan (Handle, ClientMessage) ->
                 IO ()
handlerThread users rooms incoming outgoing = do
  let continuation = handlerThread users rooms incoming outgoing in do
    (handle, msg) <- atomically $ readTChan incoming
    print ("Got message: " ++ show msg)
    (responseMsg, cont) <- do
      case msg of
        Login name -> trace ("Login: " ++ name) $ login users name handle continuation
        SPrivateMessage from to msg -> privateMessage users from to msg continuation outgoing
        SRoomMessage from room msg -> roomMessage rooms from room msg continuation outgoing
        Join name room -> trace ("Joining") joinRoom users rooms name room continuation
        Part name room -> partRoom users rooms name room continuation
        Logout name -> logout users rooms name
        Invalid -> return (Error "Invalid Command", continuation)
    atomically $ writeTChan outgoing (handle, responseMsg)
    trace "continuing" cont
  
login :: UserStore -> 
         String -> 
         Handle -> 
         IO () ->
         IO (ClientMessage, IO ())
login users name handle cont = atomically $ do
      user <- maybeGetUser users name
      case user of
        Just u ->
          return (Error "Username already in use", return ())
        Nothing -> do
          updateUser users (makeUser name handle)
          return (Ok, cont)
          
logout :: UserStore ->
          RoomStore ->
          String ->
          IO (ClientMessage, IO ())
logout userStore roomStore name = atomically $ do
  maybeUser <- maybeGetUser userStore name
  userMap <- readTVar userStore
  writeTVar userStore (M.delete name userMap)
  return (Ok, trace "handler dying" $ removeUserFromRooms maybeUser userStore roomStore)

removeUserFromRooms :: Maybe User -> UserStore -> RoomStore -> IO ()
removeUserFromRooms maybeUser userStore roomStore =
  return ()

privateMessage :: UserStore -> 
                  String -> 
                  String -> 
                  String -> 
                  IO () ->
                  TChan (Handle, ClientMessage) ->
                  IO (ClientMessage, IO ())
privateMessage userStore fromName toName msg cont chan = do
  maybeUser <- atomically $ maybeGetUser userStore toName
  case maybeUser of
    Just toUser -> return (Ok, sendPrivateMessage toUser fromName msg chan >> cont)
    Nothing -> return (Error "User is not logged in", return ())
    
sendPrivateMessage :: User -> String -> String -> TChan (Handle, ClientMessage) -> IO ()
sendPrivateMessage to fromName msg chan = atomically $
  writeTChan chan (handle to, CPrivateMessage fromName msg)

sendRoomMessage :: Room -> String -> String -> TChan (Handle, ClientMessage) -> IO ()
sendRoomMessage room from msg chan = atomically $
  (sequence (Prelude.map (\u -> writeTChan chan (handle u, CRoomMessage from (roomName room) msg)) (Prelude.filter (\u -> userName u /= from) (users room)))) >>
  return ()
    
roomMessage :: RoomStore -> 
               String -> 
               String -> 
               String -> 
               IO () ->
               TChan (Handle, ClientMessage) ->
               IO (ClientMessage, IO ())
roomMessage roomStore fromName toRoom msg cont chan = do
  maybeRoom <- atomically $ maybeGetRoom roomStore toRoom
  case maybeRoom of
    Just room -> return (Ok, sendRoomMessage room fromName msg chan >> cont)
    Nothing -> return (Error "Room does not exist", return ())
    
joinRoom :: UserStore ->
            RoomStore ->
            String ->
            String ->
            IO () ->
            IO (ClientMessage, IO ())
joinRoom userStore roomStore userName roomName cont = do
  atomically $ do
    maybeUser <- maybeGetUser userStore userName
    case maybeUser of
      Just user -> do
        room <- createRoomIfNeeded roomStore roomName
        let newUser = (user { rooms = room : (rooms user) } )
        let newRoom = (room { users = user : (users room) } )
        updateUser userStore newUser
        updateRoom roomStore newRoom
        return (Ok, cont)
      Nothing -> -- this is a bizarre situation
        return (Error "Somehow, you don't seem to be logged in. Disconnecting.", return ())
  
partRoom :: UserStore ->
            RoomStore ->
            String ->
            String ->
            IO () ->
            IO (ClientMessage, IO ())
partRoom userStore roomStore uName rName cont = do
  atomically $ do
    maybeUser <- maybeGetUser userStore uName
    case maybeUser of
      Just user -> do
        room <- createRoomIfNeeded roomStore rName
        let newUser = (user { rooms = Prelude.filter (\r -> roomName r /= roomName room) (rooms user) } )
        let newRoom = (room { users = Prelude.filter (\u -> userName u /= userName user) (users room) } )
        updateUser userStore newUser
        updateRoom roomStore newRoom
        return (Ok, cont)
      Nothing ->
        return (Error "Somehow, you don't seem to be logged in. Disconnecting.", return ())

updateUser :: UserStore -> 
              User -> 
              STM ()
updateUser userStore user = do
  userVar <- newTVar user
  userStoreMap <- readTVar userStore
  let newMap = M.insert (userName user) userVar userStoreMap
  writeTVar userStore newMap
  
updateRoom :: RoomStore -> 
              Room -> 
              STM ()
updateRoom roomStore room = trace ("Updating room " ++ show room) $ do
  roomVar <- newTVar room
  roomStoreMap <- readTVar roomStore
  let newMap = M.insert (roomName room) roomVar roomStoreMap
  writeTVar roomStore newMap
  
createRoomIfNeeded :: RoomStore ->
                      String ->
                      STM Room
createRoomIfNeeded roomStore name = do
  roomStoreMap <- readTVar roomStore
  case M.lookup name roomStoreMap of
    Just existing -> readTVar existing
    Nothing -> 
      do
        let newRoom = makeRoom name
        roomVar <- newTVar newRoom
        let newMap = M.insert (roomName newRoom) roomVar roomStoreMap
        writeTVar roomStore newMap
        return newRoom
  
maybeGetRoom :: RoomStore -> String -> STM (Maybe Room)
maybeGetRoom rooms name = do
  roomMap <- readTVar rooms
  case M.lookup name roomMap of
    Just roomVar -> do
      room <- readTVar roomVar
      return (return room)
    Nothing -> return Nothing
   
maybeGetUser :: UserStore -> String -> STM (Maybe User)
maybeGetUser userStore name = do
  userMap <- readTVar userStore
  case M.lookup name userMap of
    Just userVar -> do
      user <- readTVar userVar
      return (Just user)
    Nothing -> return Nothing
#include "GameNetwork/GeneralsOnline/NetworkMesh.h"
#include "GameNetwork/GeneralsOnline/NGMP_include.h"
#include "GameNetwork/GeneralsOnline/NGMP_interfaces.h"

#if defined(_WIN32)
#include <ws2ipdef.h>
#endif
#include "GameNetwork/NetworkDefs.h"
#include "GameNetwork/NetworkInterface.h"
#include "GameLogic/GameLogic.h"
#include "GameNetwork/GeneralsOnline/OnlineServices_RoomsInterface.h"
#include "GameNetwork/GeneralsOnline/json.hpp"
#include "GameNetwork/GeneralsOnline/HTTP/HTTPManager.h"
#include "GameNetwork/GeneralsOnline/OnlineServices_Init.h"
#include <steam/isteamnetworkingutils.h>
#include <steam/steamnetworkingcustomsignaling.h>
#include "GameNetwork/GeneralsOnline/PluginInterfaces.h"
#include <steam/isteamnetworkingsockets.h>
#include <steam/steamnetworkingsockets.h>
#include <cstring>
#include <atomic>

bool g_bForceRelay = false;
UnsignedInt m_exeCRCOriginal = 0;

// Blocks Steam connection callbacks while a NetworkMesh is tearing down.
// Closing a P2P connection can synchronously/asynchronously generate a final
// status callback; without this guard the callback can touch the mesh after
// its connection map has started being destroyed.
static std::atomic<bool> g_bNetworkMeshDestroying = false;

// Pool for deferred deletion of ConnectionSignaling objects; avoids "delete this" races during
// async Steam callbacks.
static std::mutex g_pendingDeletionMutex;
static std::vector<void*> g_pendingConnSignalingDeletions;
static std::vector<ISignalingClient*> g_pendingSignalingClientDeletions;

// Clean up pending ConnectionSignaling objects that were deferred during Release()

static void CleanupPendingConnSignalingDeletions()
{
	std::vector<void*> objectsToDelete;
	{
		std::scoped_lock<std::mutex> lock(g_pendingDeletionMutex);
		objectsToDelete.swap(g_pendingConnSignalingDeletions);
	}
	
	for (void* pObj : objectsToDelete)
	{
		// SECURITY: Delete through base interface to avoid nested class visibility issues
		delete static_cast<ISteamNetworkingConnectionSignaling*>(pObj);
	}
}

// Called on connection state transitions. Always runs on the main thread via RunCallbacks(), so
// m_mapConnections is accessed here without m_mapConnectionsMutex.
void OnSteamNetConnectionStatusChanged(SteamNetConnectionStatusChangedCallback_t* pInfo)
{
	if (g_bNetworkMeshDestroying.load(std::memory_order_acquire))
	{
		return;
	}

	if (pInfo == nullptr)
	{
		return;
	}

	CleanupPendingConnSignalingDeletions();

	NetworkMesh* pMesh = NGMP_OnlineServicesManager::GetNetworkMesh();

	if (pMesh == nullptr)
	{
		return;
	}

	// find player connection
	int64_t connectionID = -1;
	std::map<int64_t, PlayerConnection>& connections = pMesh->GetAllConnections();
	for (auto& kvPair : connections)
	{
		if (kvPair.second.m_hSteamConnection == pInfo->m_hConn)
		{
			connectionID = kvPair.first;
			break;
		}
	}


	//if (pPlayerConnection != nullptr)
	{
		//NetworkLog(ELogVerbosity::LOG_RELEASE, "[STEAM NETWORKING][%s] Player Connection was null", pInfo->m_info.m_szConnectionDescription);
		//return;
	}

	// What's the state of the connection?
	switch (pInfo->m_info.m_eState)
	{
	case k_ESteamNetworkingConnectionState_ClosedByPeer:
	case k_ESteamNetworkingConnectionState_ProblemDetectedLocally:

		NetworkLog(ELogVerbosity::LOG_RELEASE, "[STEAM NETWORKING][%s] %s, reason %d: %s\n",
			pInfo->m_info.m_szConnectionDescription,
			(pInfo->m_info.m_eState == k_ESteamNetworkingConnectionState_ClosedByPeer ? "closed by peer" : "problem detected locally"),
			pInfo->m_info.m_eEndReason,
			pInfo->m_info.m_szEndDebug
		);

		// Close our end
		NetworkLog(ELogVerbosity::LOG_RELEASE, "[DC] Closing in callback");
		SteamNetworkingSockets()->CloseConnection(pInfo->m_hConn, 0, nullptr, false);

		if (connectionID != -1 && pInfo != nullptr)
		{
			PlayerConnection& plrConnection = connections[connectionID];

			// Capture before SetDisconnected(), which can erase this entry via UpdateState().
			const int64_t userID = plrConnection.m_userID;
			const int signallingAttemptsBeforeDisconnect = plrConnection.m_SignallingAttempts;

			if (TheNetwork != nullptr)
			{
				TheNetwork->GetConnectionManager()->disconnectPlayer(userID);
			}

			NetworkLog(ELogVerbosity::LOG_RELEASE, "[DC] Closing connection %lld", userID);

			ServiceConfig& serviceConf = NGMP_OnlineServicesManager::GetInstance()->GetServiceConfig();
			const int numSignallingAttempts = 2;

			// only the later joiner of a pair gives up; unknown join order caps both sides, a departed peer is capped without leaving
			NGMP_OnlineServices_LobbyInterface* pJoinOrderLobby = NGMP_OnlineServicesManager::GetInterface<NGMP_OnlineServices_LobbyInterface>();
			const bool bWeJoinedLater = pJoinOrderLobby == nullptr || !pJoinOrderLobby->IsJoinOrderKnown() || pJoinOrderLobby->JoinedAfter(userID);
			const bool bPeerLeft = pJoinOrderLobby != nullptr && pJoinOrderLobby->IsJoinOrderKnown() && !pJoinOrderLobby->IsLobbyMember(userID);
			// a match can't leave its lobby, so keep repairing the link until the service drops the player
			const bool bInMatch = TheGameLogic != nullptr && TheGameLogic->isInInternetGame();
			bool bShouldRetry = serviceConf.retry_signalling && ((bInMatch && !bPeerLeft) || (!bWeJoinedLater && !bPeerLeft) || signallingAttemptsBeforeDisconnect < numSignallingAttempts);

			bool bWasError = pInfo->m_info.m_eState == k_ESteamNetworkingConnectionState_ProblemDetectedLocally || pInfo->m_info.m_eEndReason != k_ESteamNetConnectionEnd_App_Generic;
			plrConnection.SetDisconnected(bWasError, pMesh, bShouldRetry && bWasError);
			// plrConnection may be dangling past this point; use the captured locals.

			// the highest slot player, should leave. In most cases, this is the most recently joined player, but this may not be 100% accurate due to backfills.
			// TODO_NGMP: In the future, we should pick the most recently joined by timestamp
			if (bWasError) // only if it wasn't a clean disconnect (e.g. lobby leave)
			{
				NetworkLog(ELogVerbosity::LOG_RELEASE, "[STEAM NETWORKING][DISCONNECT HANDLER] Determined we didn't connect due to an error, Retrying: %d (currently at %d/%d attempts)", bShouldRetry, signallingAttemptsBeforeDisconnect, numSignallingAttempts);

				// should we retry signaling?
				if (bShouldRetry)
				{
					NetworkLog(ELogVerbosity::LOG_RELEASE, "[STEAM NETWORKING][DISCONNECT HANDLER] Retrying...");
					std::shared_ptr<WebSocket> pWS = NGMP_OnlineServicesManager::GetWebSocket();
					if (pWS)
					{
						NGMP_OnlineServices_AuthInterface* pAuthInterface = NGMP_OnlineServicesManager::GetInterface<NGMP_OnlineServices_AuthInterface>();
						NGMP_OnlineServices_LobbyInterface* pLobbyInterface = NGMP_OnlineServicesManager::GetInterface<NGMP_OnlineServices_LobbyInterface>();
						if (pLobbyInterface != nullptr && pAuthInterface != nullptr)
						{
							int64_t myUserID = pAuthInterface->GetUserID();

							// Behavior:
							// disconnected slot userID is higher than ours, do nothing, they will signal
							// disconnected slot userID is lower than ours, we signal
							if ((myUserID > userID))
							{
								NetworkLog(ELogVerbosity::LOG_RELEASE, "[STEAM NETWORKING][DISCONNECT HANDLER] Send signal start request...");

								pWS->SendData_RequestSignalling(userID);
							}
							else
							{
								NetworkLog(ELogVerbosity::LOG_RELEASE, "[STEAM NETWORKING][DISCONNECT HANDLER] Not sending signal start request, other player should");
							}
						}

					}
					else
					{
						// Should always have a websocket... so lets just fail
						bShouldRetry = false;
					}
				}

				if (!bShouldRetry && bPeerLeft)
				{
					NetworkLog(ELogVerbosity::LOG_RELEASE, "[STEAM NETWORKING][DISCONNECT HANDLER] Not retrying, user %lld is no longer in the lobby", userID);
				}
				else if (!bShouldRetry && !bWeJoinedLater)
				{
					NetworkLog(ELogVerbosity::LOG_RELEASE, "[STEAM NETWORKING][DISCONNECT HANDLER] Not retrying, user %lld joined after us and will leave", userID);
				}
				else if (!bShouldRetry)
				{
					NetworkLog(ELogVerbosity::LOG_RELEASE, "[STEAM NETWORKING][DISCONNECT HANDLER] Not retrying, handling disconnect as failure...");

					NGMP_OnlineServices_LobbyInterface* pLobbyInterface = NGMP_OnlineServicesManager::GetInterface<NGMP_OnlineServices_LobbyInterface>();
					if (pLobbyInterface != nullptr && pLobbyInterface->IsHost())
					{
						// the host keeps its lobby; the peer that can't connect is the one to go
						NetworkLog(ELogVerbosity::LOG_RELEASE, "[STEAM NETWORKING][DISCONNECT HANDLER] Not leaving, we host this lobby; dropping user %lld only", userID);
					}
					else if (pLobbyInterface != nullptr)
					{
						NetworkLog(ELogVerbosity::LOG_RELEASE, "[STEAM NETWORKING][DISCONNECT HANDLER] Performing local removal for user %lld from lobby due to failure to connect\n", userID);

						// deferred: the handler leaves the lobby, which deletes this mesh while we're still inside its RunCallbacks
						pLobbyInterface->QueueCannotConnectToLobby();
					}
				}
			}


			// In this example, we will bail the test whenever this happens.
			// Was this a normal termination?
			NetworkLog(ELogVerbosity::LOG_RELEASE, "[STEAM NETWORKING]DISCONNECTED OR PROBLEM DETECTED %d\n", pInfo->m_info.m_eEndReason);
		}
		else
		{
			// Why are we hearing about any another connection?
			//assert(false);
		}

		break;

	case k_ESteamNetworkingConnectionState_None:
		// Notification that a connection was destroyed.  (By us, presumably.)
		// We don't need this, so ignore it.
		break;

	case k_ESteamNetworkingConnectionState_Connecting:

		// Is this a connection we initiated, or one that we are receiving?
		if (pMesh->GetListenSocketHandle() != k_HSteamListenSocket_Invalid && pInfo->m_info.m_hListenSocket == pMesh->GetListenSocketHandle())
		{
			// Somebody's knocking
			// Note that we assume we will only ever receive a single connection

			NetworkLog(ELogVerbosity::LOG_RELEASE, "[STEAM NETWORKING][%s] Considering Accepting\n", pInfo->m_info.m_szConnectionDescription);

			if (connectionID != -1)
			{
				PlayerConnection& plrConnection = connections[connectionID];

#if _DEBUG
				if (connectionID != -1)
					assert(plrConnection.m_hSteamConnection == k_HSteamNetConnection_Invalid); // not really a bug in this code, but a bug in the test
#endif

				if (pInfo != nullptr)
				{


					plrConnection.UpdateState(EConnectionState::CONNECTING_DIRECT, pMesh);
					NetworkLog(ELogVerbosity::LOG_RELEASE, "[STEAM CONNECTION] Updating connection from %u to %u on user %lld", plrConnection.m_hSteamConnection, pInfo->m_hConn, plrConnection.m_userID);
					SteamNetworkingSockets()->SetConnectionName(pInfo->m_hConn, std::format("Steam Connection User{}", plrConnection.m_userID).c_str());
					plrConnection.m_hSteamConnection = pInfo->m_hConn;
				}

				// check user is in the lobby, otherwise reject
				NGMP_OnlineServices_LobbyInterface* pLobbyInterface = NGMP_OnlineServicesManager::GetInterface<NGMP_OnlineServices_LobbyInterface>();
				if (pLobbyInterface == nullptr)
				{
					NetworkLog(ELogVerbosity::LOG_RELEASE, "[STEAM NETWORKING][%s] Rejecting - Lobby interface is null\n", pInfo->m_info.m_szConnectionDescription);

					NetworkLog(ELogVerbosity::LOG_RELEASE, "[DC] Closing connection 2 %lld", plrConnection.m_userID);
					SteamNetworkingSockets()->CloseConnection(pInfo->m_hConn, 1000, "Lobby interface is null (Rejected)", false);

					if (TheNetwork != nullptr)
					{
						TheNetwork->GetConnectionManager()->disconnectPlayer(plrConnection.m_userID);
					}

					return;
				}

				auto currentLobby = pLobbyInterface->GetCurrentLobby();
				bool bPlayerIsInLobby = false;
				for (const auto& member : currentLobby.members)
				{
					// TODO_NGMP: Use bytes or SteamID instead... string compare is nasty
					if (std::to_string(member.user_id) == pInfo->m_info.m_identityRemote.GetGenericString())
					{
						bPlayerIsInLobby = true;
						break;
					}
				}

				if (bPlayerIsInLobby)
				{
					NetworkLog(ELogVerbosity::LOG_RELEASE, "[STEAM NETWORKING][%s] Accepting - Player is in lobby\n", pInfo->m_info.m_szConnectionDescription);
					SteamNetworkingSockets()->AcceptConnection(pInfo->m_hConn);
				}
				else
				{
					NetworkLog(ELogVerbosity::LOG_RELEASE, "[STEAM NETWORKING][%s] Rejecting - Player is not in lobby\n", pInfo->m_info.m_szConnectionDescription);

					NetworkLog(ELogVerbosity::LOG_RELEASE, "[DC] Closing connection not in lobby %lld", plrConnection.m_userID);
					SteamNetworkingSockets()->CloseConnection(pInfo->m_hConn, 1000, "Player is not in lobby (Rejected)", false);

					if (TheNetwork != nullptr)
					{
						TheNetwork->GetConnectionManager()->disconnectPlayer(plrConnection.m_userID);
					}
				}
			}
			
		}
		else
		{
			// Note that we will get notification when our own connection that
			// we initiate enters this state.
			NetworkLog(ELogVerbosity::LOG_RELEASE, "[STEAM NETWORKING][%s] Entered connecting state\n", pInfo->m_info.m_szConnectionDescription);

			if (connectionID != -1)
			{
				PlayerConnection& plrConnection = connections[connectionID];

#if _DEBUG
				if (connectionID != -1)
					assert(plrConnection.m_hSteamConnection == pInfo->m_hConn);
#endif

				plrConnection.UpdateState(EConnectionState::CONNECTING_DIRECT, pMesh);
			}
		}
		break;

	case k_ESteamNetworkingConnectionState_FindingRoute:
		// P2P connections will spend a brief time here where they swap addresses
		// and try to find a route.
		if (connectionID != -1 && pInfo != nullptr)
		{
			NetworkLog(ELogVerbosity::LOG_RELEASE, "[STEAM NETWORKING][%s] finding route\n", pInfo->m_info.m_szConnectionDescription);

			PlayerConnection& plrConnection = connections[connectionID];
			plrConnection.UpdateState(EConnectionState::FINDING_ROUTE, pMesh);
		}
		break;

	case k_ESteamNetworkingConnectionState_Connected:
		// We got fully connected
#if _DEBUG
		//assert(pInfo->m_hConn == pPlayerConnection->m_hSteamConnection); // We don't initiate or accept any other connections, so this should be out own connection
#endif

		NetworkLog(ELogVerbosity::LOG_RELEASE, "[STEAM NETWORKING][%s] connected\n", pInfo->m_info.m_szConnectionDescription);

		if (pInfo->m_info.m_nFlags & k_nSteamNetworkConnectionInfoFlags_Unauthenticated)
		{
			NetworkLog(ELogVerbosity::LOG_RELEASE, "[CONNECTION FLAGS]: has k_nSteamNetworkConnectionInfoFlags_Unauthenticated");
		}
		else if (pInfo->m_info.m_nFlags & k_nSteamNetworkConnectionInfoFlags_Unencrypted)
		{
			NetworkLog(ELogVerbosity::LOG_RELEASE, "[CONNECTION FLAGS]: has k_nSteamNetworkConnectionInfoFlags_Unencrypted");
		}
		else if (pInfo->m_info.m_nFlags & k_nSteamNetworkConnectionInfoFlags_LoopbackBuffers)
		{
			NetworkLog(ELogVerbosity::LOG_RELEASE, "[CONNECTION FLAGS]: has k_nSteamNetworkConnectionInfoFlags_LoopbackBuffers");
		}
		else if (pInfo->m_info.m_nFlags & k_nSteamNetworkConnectionInfoFlags_Fast)
		{
			NetworkLog(ELogVerbosity::LOG_RELEASE, "[CONNECTION FLAGS]: has k_nSteamNetworkConnectionInfoFlags_Fast");
		}
		else if (pInfo->m_info.m_nFlags & k_nSteamNetworkConnectionInfoFlags_Relayed)
		{
			NetworkLog(ELogVerbosity::LOG_RELEASE, "[CONNECTION FLAGS]: has k_nSteamNetworkConnectionInfoFlags_Relayed");
		}
		else if (pInfo->m_info.m_nFlags & k_nSteamNetworkConnectionInfoFlags_DualWifi)
		{
			NetworkLog(ELogVerbosity::LOG_RELEASE, "[CONNECTION FLAGS]: has k_nSteamNetworkConnectionInfoFlags_DualWifi");
		}

		if (connectionID != -1)
		{
			PlayerConnection& plrConnection = connections[connectionID];

			plrConnection.UpdateState(EConnectionState::CONNECTED_DIRECT, pMesh);
		}

		break;

	default:
		NetworkLog(ELogVerbosity::LOG_RELEASE, "[STEAM CALLBACK] Unhandled case");
		break;
	}
}

/// Implementation of ITrivialSignalingClient
class CSignalingClient : public ISignalingClient
{

	// This is the thing we'll actually create to send signals for a particular
	// connection.
	struct ConnectionSignaling : ISteamNetworkingConnectionSignaling
	{
		CSignalingClient* const m_pOwner;
		int64_t const m_targetUserID;

		ConnectionSignaling(CSignalingClient* owner, int64_t target_user_id)
			: m_pOwner(owner)
			, m_targetUserID(target_user_id)
		{
		}

		//
		// Implements ISteamNetworkingConnectionSignaling
		//

		// This is called from SteamNetworkingSockets to send a signal.  This could be called from any thread,
		// so we need to be threadsafe, and avoid duoing slow stuff or calling back into SteamNetworkingSockets
		virtual bool SendSignal(HSteamNetConnection hConn, const SteamNetConnectionInfo_t& info, const void* pMsg, int cbMsg) override
		{
			// Silence warnings
			(void)info;
			(void)hConn;

			std::vector<uint8_t> vecPayload(cbMsg);
			std::memcpy(vecPayload.data(), pMsg, static_cast<size_t>(cbMsg));

			m_pOwner->Send(m_targetUserID, vecPayload);
			return true;
		}

		// Self destruct.  This will be called by SteamNetworkingSockets when it's done with us.
		virtual void Release() override
		{
			// SECURITY FIX: Avoid immediate "delete this" which can cause use-after-free
			// when called from async Steam callbacks. Instead, defer deletion to prevent
			// races where CSignalingClient might be destroyed while this object is still
			// being accessed or its owner pointer is being used.
			std::scoped_lock<std::mutex> lock(g_pendingDeletionMutex);
			g_pendingConnSignalingDeletions.push_back(static_cast<void*>(this));
		}
	};

	struct QueuedSend
	{
		int64_t target_user_id;
		std::vector<uint8_t> vecPayload;
	};
	ISteamNetworkingSockets* const m_pSteamNetworkingSockets;

	// Guards m_queueSend; SendSignal() may run on any thread, Poll() drains on the main thread.
	std::mutex m_sendQueueMutex;
	std::deque<QueuedSend> m_queueSend;

	void CloseSocket()
	{
		std::scoped_lock<std::mutex> lock(m_sendQueueMutex);
		m_queueSend.clear();
	}

public:
	CSignalingClient(ISteamNetworkingSockets* pSteamNetworkingSockets)
		:  m_pSteamNetworkingSockets(pSteamNetworkingSockets)
	{
		// Save off our identity
		SteamNetworkingIdentity identitySelf; identitySelf.Clear();
		pSteamNetworkingSockets->GetIdentity(&identitySelf);

		if (identitySelf.IsInvalid())
		{
			NetworkLog(ELogVerbosity::LOG_RELEASE, "CSignalingClient: Local identity is invalid\n");
		}

		if (identitySelf.IsLocalHost())
		{
			NetworkLog(ELogVerbosity::LOG_RELEASE, "CSignalingClient: Local identity is localhost\n");
		}

	}

	// May be called from any thread; always queues, Poll() flushes on the main thread.
	void Send(int64_t target_user_id, std::vector<uint8_t>& vecPayload)
	{
		std::scoped_lock<std::mutex> lock(m_sendQueueMutex);

		// Best-effort delivery; drop oldest on backlog.
		while (m_queueSend.size() > 128)
		{
			NetworkLog(ELogVerbosity::LOG_RELEASE, "Signaling send queue is backed up.  Discarding oldest signals\n");
			m_queueSend.pop_front();
		}

		QueuedSend newEntry = QueuedSend();
		newEntry.target_user_id = target_user_id;
		newEntry.vecPayload = vecPayload;
		m_queueSend.push_back(newEntry);
	}

	ISteamNetworkingConnectionSignaling* CreateSignalingForConnection(
		const SteamNetworkingIdentity& identityPeer,
		SteamNetworkingErrMsg& errMsg
	) override {
		SteamNetworkingIdentityRender sIdentityPeer(identityPeer);

		// FIXME - here we really ought to confirm that the string version of the
		// identity does not have spaces, since our protocol doesn't permit it.
		NetworkLog(ELogVerbosity::LOG_DEBUG, "Creating signaling session for peer '%s'\n", sIdentityPeer.c_str());

		// Silence warnings
		(void)errMsg;

		const char* identity = identityPeer.GetGenericString();
		if (identity == nullptr || identity[0] == '\0')
		{
			NetworkLog(ELogVerbosity::LOG_RELEASE, "[STEAM NETWORKING] Rejecting signalling peer with empty identity");
			return nullptr;
		}

		try
		{
			size_t parsedChars = 0;
			const int64_t user_id = std::stoll(identity, &parsedChars);
			if (parsedChars != std::strlen(identity) || user_id <= 0)
			{
				NetworkLog(ELogVerbosity::LOG_RELEASE, "[STEAM NETWORKING] Rejecting invalid signalling identity '%s'", identity);
				return nullptr;
			}
			return new ConnectionSignaling(this, user_id);
		}
		catch (const std::exception&)
		{
			NetworkLog(ELogVerbosity::LOG_RELEASE, "[STEAM NETWORKING] Rejecting unparsable signalling identity '%s'", identity);
			return nullptr;
		}
	}

	inline int HexDigitVal(char c)
	{
		if ('0' <= c && c <= '9')
			return c - '0';
		if ('a' <= c && c <= 'f')
			return c - 'a' + 0xa;
		if ('A' <= c && c <= 'F')
			return c - 'A' + 0xa;
		return -1;
	}

	virtual void Poll() override
	{
		std::shared_ptr<WebSocket> pWS = NGMP_OnlineServicesManager::GetWebSocket();
		if (pWS)
		{
			std::deque<QueuedSend> sendBatch;
			{
				std::scoped_lock<std::mutex> lock(m_sendQueueMutex);
				sendBatch.swap(m_queueSend);
			}

			while (!sendBatch.empty())
			{
				QueuedSend sendData = sendBatch.front();

				pWS->SendData_Signalling(sendData.target_user_id, sendData.vecPayload);
				sendBatch.pop_front();
			}

			std::queue<std::vector<uint8_t>> pendingSignals = pWS->DrainPendingSignals();

			// Now dispatch any buffered signals
			if (!pendingSignals.empty())
			{
				NetworkLog(ELogVerbosity::LOG_RELEASE, "[SIGNAL] PROCESS SIGNAL!");
				while (!pendingSignals.empty())
				{
					// NOTE: outbound msg doesnt need sender ID, we only need that to determine target on the server, everything else is included in the payload
					// 
					// Get the next signal
					std::vector<uint8_t> signalData = pendingSignals.front();
					pendingSignals.pop();

					// Setup a context object that can respond if this signal is a connection request.
					struct Context : ISteamNetworkingSignalingRecvContext
					{
						CSignalingClient* m_pOwner;

						virtual ISteamNetworkingConnectionSignaling* OnConnectRequest(
							HSteamNetConnection hConn,
							const SteamNetworkingIdentity& identityPeer,
							int nLocalVirtualPort
						) override {
							// Silence warnings
							(void)hConn;
							;						(void)nLocalVirtualPort;

							// We will just always handle requests through the usual listen socket state
							// machine.  See the documentation for this function for other behaviour we
							// might take.

							// Also, note that if there was routing/session info, it should have been in
							// our envelope that we know how to parse, and we should save it off in this
							// context object.
							SteamNetworkingErrMsg ignoreErrMsg;
							return m_pOwner->CreateSignalingForConnection(identityPeer, ignoreErrMsg);
						}
						
						virtual void SendRejectionSignal(
							const SteamNetworkingIdentity& identityPeer,
							const void* pMsg, int cbMsg
						) override {

							// We'll just silently ignore all failures.  This is actually the more secure
							// Way to handle it in many cases.  Actively returning failure might allow
							// an attacker to just scrape random peers to see who is online.  If you know
							// the peer has a good reason for trying to connect, sending an active failure
							// can improve error handling and the UX, instead of relying on timeout.  But
							// just consider the security implications.
							NetworkLog(ELogVerbosity::LOG_RELEASE, "[STEAM NETWORKING] Sending rejection signal");
							// Silence warnings
							(void)identityPeer;
							(void)pMsg;
							(void)cbMsg;
						}
					};
					Context context;
					context.m_pOwner = this;

					// Dispatch.
					// Remember: From inside this function, our context object might get callbacks.
					// And we might get asked to send signals, either now, or really at any time
					// from any thread!  If possible, avoid calling this function while holding locks.
					// To process this call, SteamnetworkingSockets will need take its own internal lock.
					// That lock may be held by another thread that is asking you to send a signal!  So
					// be warned that deadlocks are a possibility here.
					m_pSteamNetworkingSockets->ReceivedP2PCustomSignal(signalData.data(), (int)signalData.size(), &context);
				}
			}
		}
		}


	virtual void Release() override
	{
		// NOTE: Here we are assuming that the calling code has already cleaned
		// up all the connections, to keep the example simple.
		CloseSocket();
	}
};


bool NetworkMeshLibrary::s_bInitialized = false;

bool NetworkMeshLibrary::EnsureInitialized(int64_t userID)
{
	// lives until the online services shut down; a new login always follows a full teardown
	if (s_bInitialized)
	{
		return true;
	}

	SteamNetworkingIdentity identityLocal;
	identityLocal.Clear();
	std::string userIDStr = std::to_string(userID);
	identityLocal.SetGenericString(userIDStr.c_str());

	if (identityLocal.IsInvalid())
	{
		NetworkLog(ELogVerbosity::LOG_RELEASE, "NetworkMeshLibrary::EnsureInitialized: SteamNetworkingIdentity is invalid");
		return false;
	}

	SteamDatagramErrMsg errMsg;
	if (!GameNetworkingSockets_Init(&identityLocal, errMsg))
	{
		NetworkLog(ELogVerbosity::LOG_RELEASE, "NetworkMeshLibrary::EnsureInitialized: GameNetworkingSockets_Init failed. %s", errMsg);
		return false;
	}

	s_bInitialized = true;

	// Every STUN entry must resolve to a distinct address, or the native ICE client retries
	// duplicates forever.
	SteamNetworkingUtils()->SetGlobalConfigValueString(k_ESteamNetworkingConfig_P2P_STUN_ServerList, "stun:stun.playgenerals.online:53,stun:stun.playgenerals.online:3478,stun:stun.l.google.com:19302");


	ESteamNetworkingSocketsDebugOutputType logType =
#if defined(_DEBUG)
		ESteamNetworkingSocketsDebugOutputType::k_ESteamNetworkingSocketsDebugOutputType_Debug;
#else
		NGMP_OnlineServicesManager::Settings.Debug_VerboseLogging() ? ESteamNetworkingSocketsDebugOutputType::k_ESteamNetworkingSocketsDebugOutputType_Debug : ESteamNetworkingSocketsDebugOutputType::k_ESteamNetworkingSocketsDebugOutputType_Msg;
#endif

	SteamNetworkingUtils()->SetGlobalConfigValueInt32(k_ESteamNetworkingConfig_LogLevel_P2PRendezvous, logType);
	SteamNetworkingUtils()->SetDebugOutputFunction(logType, [](ESteamNetworkingSocketsDebugOutputType nType, const char* pszMsg)
		{
			NetworkLog(ELogVerbosity::LOG_RELEASE, "[STEAM NETWORKING LOGFUNC] %s", pszMsg);
		});

	SteamNetworkingUtils()->SetGlobalCallback_SteamNetConnectionStatusChanged(OnSteamNetConnectionStatusChanged);

	return true;
}

void NetworkMeshLibrary::Shutdown()
{
	if (!s_bInitialized)
	{
		return;
	}

	// Stop callbacks before tearing down sockets.  Signalling objects may still be
	// referenced by Steam until GameNetworkingSockets_Kill() completes.
	SteamNetworkingUtils()->SetGlobalCallback_SteamNetConnectionStatusChanged(nullptr);
	GameNetworkingSockets_Kill();

	CleanupPendingConnSignalingDeletions();

	std::vector<ISignalingClient*> clientsToDelete;
	{
		std::scoped_lock<std::mutex> lock(g_pendingDeletionMutex);
		clientsToDelete.swap(g_pendingSignalingClientDeletions);
	}
	for (ISignalingClient* pClient : clientsToDelete)
	{
		delete pClient;
	}

	s_bInitialized = false;
}

void NetworkMeshLibrary::QueueSignalingClientForDeferredDeletion(ISignalingClient* pClient)
{
	if (pClient == nullptr)
	{
		return;
	}

	std::scoped_lock<std::mutex> lock(g_pendingDeletionMutex);
	g_pendingSignalingClientDeletions.push_back(pClient);
}

void NetworkMeshLibrary::Tick()
{
	if (!s_bInitialized || AnticheatPlugInterface::DoesACPluginProvideSecureGameTransport())
	{
		return;
	}

	if (SteamNetworkingSockets())
	{
		SteamNetworkingSockets()->RunCallbacks();
	}
}

NetworkMesh::NetworkMesh()
{
	NGMP_OnlineServicesManager* pOnlineServicesMgr = NGMP_OnlineServicesManager::GetInstance();
	if (pOnlineServicesMgr == nullptr)
	{
		NetworkLog(ELogVerbosity::LOG_RELEASE, "pOnlineServicesMgr is invalid");
		return;
	}

	NGMP_OnlineServices_AuthInterface* pAuthInterface = NGMP_OnlineServicesManager::GetInterface<NGMP_OnlineServices_AuthInterface>();
	if (pAuthInterface == nullptr)
	{
		NetworkLog(ELogVerbosity::LOG_RELEASE, "pAuthInterface is invalid");
		return;
	}

	NGMP_OnlineServices_LobbyInterface* pLobbyInterface = NGMP_OnlineServicesManager::GetInterface<NGMP_OnlineServices_LobbyInterface>();
	if (pLobbyInterface == nullptr)
	{
		NetworkLog(ELogVerbosity::LOG_RELEASE, "pLobbyInterface is invalid");
		return;
	}

	if (!NetworkMeshLibrary::EnsureInitialized(pAuthInterface->GetUserID()))
	{
		NetworkLog(ELogVerbosity::LOG_RELEASE, "NetworkMeshLibrary::EnsureInitialized failed");
		return;
	}

	// comma-separated; no "?transport=udp" suffix, the native ICE client takes everything after
	// the host as the port
	m_strTurnServerList = "turn:turn.playgenerals.online:53,turn:turn.playgenerals.online:3478";

	m_strTurnUsername = pLobbyInterface->GetLobbyTurnUsername();
	m_strTurnToken = pLobbyInterface->GetLobbyTurnToken();
	m_strTurnUsernameString = std::format("{},{}", m_strTurnUsername.c_str(), m_strTurnUsername.c_str());
	m_strTurnTokenString = std::format("{},{}", m_strTurnToken.c_str(), m_strTurnToken.c_str());

	ServiceConfig& serviceConf = pOnlineServicesMgr->GetServiceConfig();
	m_iceEnable = (g_bForceRelay || serviceConf.relay_all_traffic)
		? k_nSteamNetworkingConfig_P2P_Transport_ICE_Enable_Relay
		: k_nSteamNetworkingConfig_P2P_Transport_ICE_Enable_All;

// Do not force a platform-specific ICE transport here. In the crash log from
	// the iOS build, the native ICE/STUN worker itself faults in
	// ICESessionInterface::SendPacketGather while processing a STUN request.
	// Keeping the transport policy identical to the service configuration avoids
	// the iOS-only relay/native combination that was triggering that path.
	NetworkLog(ELogVerbosity::LOG_RELEASE,
		"NetworkMesh: ICE transport mode=%d (relay=%d)",
		m_iceEnable, serviceConf.relay_all_traffic ? 1 : 0);

	// 0 = library default, 1 = native, 2 = WebRTC.
	// Apple/iOS must not silently rewrite a configured implementation to 1:
	// the fault was observed specifically inside the native ICE implementation.
	m_iceImplementation = (serviceConf.ice_implementation >= 0 && serviceConf.ice_implementation <= 2)
		? serviceConf.ice_implementation
		: 0;
#if defined(__APPLE__)
	if (m_iceImplementation == 2)
	{
		// This build does not ship the optional WebRTC backend. Fall back to
		// the library default instead of explicitly selecting native ICE.
		m_iceImplementation = 0;
		NetworkLog(ELogVerbosity::LOG_RELEASE,
			"NetworkMesh: Apple build cannot use WebRTC ICE; using library-default ICE implementation 0");
	}
#endif
	NetworkLog(ELogVerbosity::LOG_RELEASE,
		"NetworkMesh: using ICE implementation %d (0=default, 1=native, 2=WebRTC)",
		m_iceImplementation);

	m_pSignaling = new CSignalingClient(SteamNetworkingSockets());
	if (m_pSignaling == nullptr)
	{
		NetworkLog(ELogVerbosity::LOG_RELEASE, "CreateTrivialSignalingClient failed");
		return;
	}

	std::vector<SteamNetworkingConfigValue_t> vecListenOpts;
	SteamNetworkingConfigValue_t opt;
	opt.SetInt32(k_ESteamNetworkingConfig_SymmetricConnect, 1);
	vecListenOpts.push_back(opt);
	opt.SetInt32(k_ESteamNetworkingConfig_P2P_Transport_ICE_Enable, m_iceEnable);
	vecListenOpts.push_back(opt);
	opt.SetInt32(k_ESteamNetworkingConfig_P2P_Transport_ICE_Implementation, m_iceImplementation);
	vecListenOpts.push_back(opt);
	opt.SetString(k_ESteamNetworkingConfig_P2P_TURN_ServerList, m_strTurnServerList.c_str());
	vecListenOpts.push_back(opt);
	opt.SetString(k_ESteamNetworkingConfig_P2P_TURN_UserList, m_strTurnUsernameString.c_str());
	vecListenOpts.push_back(opt);
	opt.SetString(k_ESteamNetworkingConfig_P2P_TURN_PassList, m_strTurnTokenString.c_str());
	vecListenOpts.push_back(opt);

	int localPort = 0;
	m_hListenSock = SteamNetworkingSockets()->CreateListenSocketP2P(localPort, (int)vecListenOpts.size(), vecListenOpts.data());

	if (m_hListenSock == k_HSteamListenSocket_Invalid)
	{
		NetworkLog(ELogVerbosity::LOG_RELEASE, "CreateListenSocketP2P failed. Sock was invalid");
		return;
	}

	m_bInitialized = true;
}


void NetworkMesh::Flush()
{
	ServiceConfig& serviceConf = NGMP_OnlineServicesManager::GetInstance()->GetServiceConfig();
	bool bDoImmediateFlushPerFrame = serviceConf.network_do_immediate_flush_per_frame;

	if (bDoImmediateFlushPerFrame)
	{
		for (auto& connectionData : m_mapConnections)
		{
			if (connectionData.second.m_hSteamConnection != k_HSteamNetConnection_Invalid)
			{
				SteamNetworkingSockets()->FlushMessagesOnConnection(connectionData.second.m_hSteamConnection);
			}
		}
	}
}


void NetworkMesh::RegisterConnectivity(int64_t userID)
{
	nlohmann::json j;
	j["target"] = userID;
	j["direct"] = false;
	j["outcome"] = EConnectionState::NOT_CONNECTED;
	j["ipv4"] = true;
	std::string strPostData = j.dump();
	std::string strURI = NGMP_OnlineServicesManager::GetAPIEndpoint("ConnectionOutcome");
	std::map<std::string, std::string> mapHeaders;
	NGMP_OnlineServicesManager::GetInstance()->GetHTTPManager()->SendPOSTRequest(strURI.c_str(), EIPProtocolVersion::DONT_CARE, mapHeaders, strPostData.c_str(), [=](bool bSuccess, int statusCode, std::string strBody, HTTPRequest* pReq)
		{
			// dont care about the response
		});
}

void NetworkMesh::UpdateConnectivity(PlayerConnection* connection)
{
	nlohmann::json j;
	j["target"] = connection->m_userID;
	j["direct"] = connection->IsDirect();
	j["outcome"] = connection->GetState();
	j["ipv4"] = connection->IsIPV4();
	std::string strPostData = j.dump();
	std::string strURI = NGMP_OnlineServicesManager::GetAPIEndpoint("ConnectionOutcome");
	std::map<std::string, std::string> mapHeaders;
	NGMP_OnlineServicesManager::GetInstance()->GetHTTPManager()->SendPOSTRequest(strURI.c_str(), EIPProtocolVersion::DONT_CARE, mapHeaders, strPostData.c_str(), [=](bool bSuccess, int statusCode, std::string strBody, HTTPRequest* pReq)
		{
			// dont care about the response
		});
}

int NetworkMesh::SendGamePacket(void* pBuffer, uint32_t totalDataSize, int64_t user_id)
{
	if (!pBuffer || totalDataSize == 0)
	{
		NetworkLog(ELogVerbosity::LOG_RELEASE, "[SendGamePacket] CRITICAL: Received null pBuffer or zero size from user %lld, size=%u", static_cast<long long>(user_id), totalDataSize);
		return -3;  // Invalid buffer
	}

	// Thread safety: Lock connection map during access
	std::lock_guard<std::recursive_mutex> lock(m_mapConnectionsMutex);
	
	auto it = m_mapConnections.find(user_id);
	if (it != m_mapConnections.end())
	{
		return it->second.SendGamePacket(pBuffer, totalDataSize);
	}
	
	NetworkLog(ELogVerbosity::LOG_RELEASE, "[SendGamePacket] Connection not found for user %lld", static_cast<long long>(user_id));
	return -2;
}


void NetworkMesh::SendACPacket(uint32_t userID, const void* pData, uint32_t dataLen)
{
    if (dataLen == 0)
    {
        NetworkLog(ELogVerbosity::LOG_RELEASE, "[AC] Cannot send empty AC packet to user %u", userID);
        return;
    }

    if (pData == nullptr)
    {
        NetworkLog(ELogVerbosity::LOG_RELEASE, "[AC] Cannot send AC packet with null data to user %u", userID);
        return;
    }

	// Thread safety: Lock connection map during access
	std::lock_guard<std::recursive_mutex> lock(m_mapConnectionsMutex);

    if (m_mapConnections.contains(userID))
    {
        m_mapConnections[userID].SendACPacket(pData, dataLen);
    }
	else
	{
		NetworkLog(ELogVerbosity::LOG_RELEASE, "[AC] Send Packet ERR - user %u not found in connections", userID);
	}
}

void NetworkMesh::StartConnectionSignalling(const char* szMiddlewareID, int64_t remoteUserID, uint16_t preferredPort)
{
	// Thread safety: Lock connection map during access
	std::lock_guard<std::recursive_mutex> lock(m_mapConnectionsMutex);

	if (AnticheatPlugInterface::DoesACPluginProvideSecureGameTransport())
	{
		// TODO_EOS: if we already have a connection to this use, drop it, having a single-direction connection will break signalling
		AnticheatPlugInterface::StartSignalling(szMiddlewareID, remoteUserID);

        // create a local user type
        {
            std::lock_guard<std::recursive_mutex> lock(m_mapConnectionsMutex);
            auto it = m_mapConnections.find(remoteUserID);
            int previousAttempts = it != m_mapConnections.end() ? it->second.m_SignallingAttempts : 0;
            m_mapConnections[remoteUserID] = PlayerConnection(remoteUserID, szMiddlewareID);

            // add attempt; carried over so the retry cap holds across re-signals
            m_mapConnections[remoteUserID].m_SignallingAttempts = previousAttempts + 1;
        }
	}
	else
	{
        // no relay without our TURN credentials
        if (m_bAwaitingTurnCredentials)
        {
            NetworkLog(ELogVerbosity::LOG_RELEASE, "[SIGNAL] Holding signalling with %lld until our TURN credentials arrive", remoteUserID);
            m_vecSignallingAwaitingTurn.push_back({ szMiddlewareID != nullptr ? szMiddlewareID : "", remoteUserID, preferredPort });
            return;
        }

        // Do not tear down an existing Steam connection just because a duplicate
        // signalling message arrived. GNS keeps the old ICE/STUN state alive on
        // its networking thread; closing and erasing the PlayerConnection here
        // while that state is still active can create two competing P2P
        // connections and leave ICE/STUN touching stale socket state.
        int previousAttempts = 0;
        auto it = m_mapConnections.find(remoteUserID);
        if (it != m_mapConnections.end())
        {
            previousAttempts = it->second.m_SignallingAttempts;

            if (it->second.m_hSteamConnection != k_HSteamNetConnection_Invalid)
            {
                NetworkLog(ELogVerbosity::LOG_RELEASE,
                    "[SIGNAL] Ignoring duplicate signalling for user %lld; existing Steam connection %u is still active",
                    remoteUserID, it->second.m_hSteamConnection);
                return;
            }

            NetworkLog(ELogVerbosity::LOG_DEBUG, "[ERASE] Removing stale invalid connection for user %lld", it->second.m_userID);
            m_mapConnections.erase(it);
        }

        NGMP_OnlineServicesManager* pOnlineServicesMgr = NGMP_OnlineServicesManager::GetInstance();
        NGMP_OnlineServices_AuthInterface* pAuthInterface = NGMP_OnlineServicesManager::GetInterface<NGMP_OnlineServices_AuthInterface>();

        if (pAuthInterface == nullptr || pOnlineServicesMgr == nullptr)
        {
            NetworkLog(ELogVerbosity::LOG_RELEASE, "NetworkMesh::ConnectToSingleUser - Auth or OSM interface is null");
            return;
        }

        // never connect to ourself
        if (remoteUserID == pAuthInterface->GetUserID())
        {
            NetworkLog(ELogVerbosity::LOG_RELEASE, "NetworkMesh::ConnectToSingleUser - Skipping connection to user %lld - user is local", remoteUserID);
            return;
        }

        SteamNetworkingIdentity identityRemote;
        identityRemote.Clear();
        std::string remoteUserIDStr = std::to_string(remoteUserID);
        identityRemote.SetGenericString(remoteUserIDStr.c_str());

        if (identityRemote.IsInvalid())
        {
            // TODO_STEAM: Handle this better
            NetworkLog(ELogVerbosity::LOG_RELEASE, "NetworkMesh::ConnectToSingleUser - SteamNetworkingIdentity is invalid");
            return;
        }

        std::vector<SteamNetworkingConfigValue_t > vecOpts;

        ServiceConfig& serviceConf = pOnlineServicesMgr->GetServiceConfig();

        int g_nLocalPort = 0;

        int g_nVirtualPortRemote = serviceConf.use_mapped_port ? preferredPort : 0;

        // Our remote and local port don't match, so we need to set it explicitly
        if (g_nVirtualPortRemote != g_nLocalPort)
        {
            SteamNetworkingConfigValue_t opt;
            opt.SetInt32(k_ESteamNetworkingConfig_LocalVirtualPort, g_nLocalPort);
            vecOpts.push_back(opt);
        }

        // Set symmetric connect mode
        SteamNetworkingConfigValue_t opt;
        opt.SetInt32(k_ESteamNetworkingConfig_SymmetricConnect, 1);
        vecOpts.push_back(opt);

        opt.SetInt32(k_ESteamNetworkingConfig_P2P_Transport_ICE_Enable, m_iceEnable);
        vecOpts.push_back(opt);
        opt.SetInt32(k_ESteamNetworkingConfig_P2P_Transport_ICE_Implementation, m_iceImplementation);
        vecOpts.push_back(opt);
        opt.SetString(k_ESteamNetworkingConfig_P2P_TURN_ServerList, m_strTurnServerList.c_str());
        vecOpts.push_back(opt);
        opt.SetString(k_ESteamNetworkingConfig_P2P_TURN_UserList, m_strTurnUsernameString.c_str());
        vecOpts.push_back(opt);
        opt.SetString(k_ESteamNetworkingConfig_P2P_TURN_PassList, m_strTurnTokenString.c_str());
        vecOpts.push_back(opt);

        NetworkLog(ELogVerbosity::LOG_DEBUG, "Connecting to '%s' in symmetric mode, virtual port %d, from local virtual port %d.\n",
            SteamNetworkingIdentityRender(identityRemote).c_str(), g_nVirtualPortRemote, g_nLocalPort);

        if (m_pSignaling == nullptr)
        {
            NetworkLog(ELogVerbosity::LOG_RELEASE, "NetworkMesh::StartConnectionSignalling - Signalling client is null (mesh failed to initialize)");
            return;
        }

        // create a signaling object for this connection
        SteamNetworkingErrMsg errMsg;
        ISteamNetworkingConnectionSignaling* pConnSignaling = m_pSignaling->CreateSignalingForConnection(identityRemote, errMsg);

        if (pConnSignaling == nullptr)
        {
            // TODO_STEAM: Handle this better
            NetworkLog(ELogVerbosity::LOG_RELEASE, "NetworkMesh::ConnectToSingleUser - Could not create signalling object, error was %s", errMsg);
            return;
        }

        // make a steam connection obj
        HSteamNetConnection hSteamConnection = SteamNetworkingSockets()->ConnectP2PCustomSignaling(pConnSignaling, &identityRemote, g_nVirtualPortRemote, (int)vecOpts.size(), vecOpts.data());

        if (hSteamConnection == k_HSteamNetConnection_Invalid)
        {
            // TODO_STEAM: Handle this better
            NetworkLog(ELogVerbosity::LOG_RELEASE, "NetworkMesh::ConnectToSingleUser - Steam network connection obj was k_HSteamNetConnection_Invalid");
            return;
        }

        // create a local user type
        {
            std::lock_guard<std::recursive_mutex> lock(m_mapConnectionsMutex);
            m_mapConnections[remoteUserID] = PlayerConnection(remoteUserID, hSteamConnection);

            // add attempt; carried over so the retry cap holds across re-signals
            m_mapConnections[remoteUserID].m_SignallingAttempts = previousAttempts + 1;
        }
	}

}

void NetworkMesh::AwaitTurnCredentials()
{
	std::lock_guard<std::recursive_mutex> lock(m_mapConnectionsMutex);
	m_bAwaitingTurnCredentials = true;
}

void NetworkMesh::SetTurnCredentials(const std::string& strUsername, const std::string& strToken)
{
	std::vector<PendingSignalling> vecPending;
	{
		std::lock_guard<std::recursive_mutex> lock(m_mapConnectionsMutex);

		m_strTurnUsername = strUsername;
		m_strTurnToken = strToken;
		m_strTurnUsernameString = std::format("{},{}", m_strTurnUsername.c_str(), m_strTurnUsername.c_str());
		m_strTurnTokenString = std::format("{},{}", m_strTurnToken.c_str(), m_strTurnToken.c_str());

		// incoming connections use the listen socket's TURN settings
		if (m_hListenSock != k_HSteamListenSocket_Invalid)
		{
			SteamNetworkingUtils()->SetConfigValue(k_ESteamNetworkingConfig_P2P_TURN_UserList, k_ESteamNetworkingConfig_ListenSocket,
				(intptr_t)m_hListenSock, k_ESteamNetworkingConfig_String, m_strTurnUsernameString.c_str());
			SteamNetworkingUtils()->SetConfigValue(k_ESteamNetworkingConfig_P2P_TURN_PassList, k_ESteamNetworkingConfig_ListenSocket,
				(intptr_t)m_hListenSock, k_ESteamNetworkingConfig_String, m_strTurnTokenString.c_str());
		}

		m_bAwaitingTurnCredentials = false;
		vecPending.swap(m_vecSignallingAwaitingTurn);
	}

	NetworkLog(ELogVerbosity::LOG_RELEASE, "[SIGNAL] Got TURN credentials, starting %d held signalling request(s)", (int)vecPending.size());
	for (const PendingSignalling& pending : vecPending)
	{
		StartConnectionSignalling(pending.strMiddlewareID.c_str(), pending.remoteUserID, pending.preferredPort);
	}
}


void NetworkMesh::DisconnectUser(int64_t remoteUserID)
{
	std::lock_guard<std::recursive_mutex> lock(m_mapConnectionsMutex);
	
	NetworkLog(ELogVerbosity::LOG_RELEASE, "[DC] Dumping all Steam connections");
	for (auto& kvPair : m_mapConnections)
	{
		NetworkLog(ELogVerbosity::LOG_RELEASE, "[DC] Dumped steam connection, Handle %u User %lld (%lld)", kvPair.second.m_hSteamConnection, kvPair.second.m_userID, kvPair.first);
	}

	if (m_mapConnections.find(remoteUserID) != m_mapConnections.end())
	{

        if (AnticheatPlugInterface::DoesACPluginProvideSecureGameTransport())
        {
            NetworkLog(ELogVerbosity::LOG_RELEASE, "[DC] Closing connection %lld", remoteUserID);

			AnticheatPlugInterface::DisconnectPlayer(m_mapConnections[remoteUserID].m_strMiddlewareID.c_str(), m_mapConnections[remoteUserID].m_userID);
            if (TheNetwork != nullptr)
            {
                TheNetwork->GetConnectionManager()->disconnectPlayer(remoteUserID);
            }
        }
		else
		{
            if (m_mapConnections[remoteUserID].m_hSteamConnection != k_HSteamNetConnection_Invalid)
            {
                NetworkLog(ELogVerbosity::LOG_RELEASE, "[DC] Closing connection %lld", remoteUserID);
                NetworkLog(ELogVerbosity::LOG_RELEASE, "[DC] Steam connection handle is %u", m_mapConnections[remoteUserID].m_hSteamConnection);

                SteamNetworkingSockets()->CloseConnection(m_mapConnections[remoteUserID].m_hSteamConnection, 0, "Client Disconnecting Gracefully (Got EWebSocketMessageID::NETWORK_CONNECTION_DISCONNECT_PLAYER from service)", false);
                if (TheNetwork != nullptr)
                {
                    TheNetwork->GetConnectionManager()->disconnectPlayer(remoteUserID);
                }
            }
		}


		if (TheNGMPGame && !TheNGMPGame->isGameInProgress())
		{
			for (auto it = m_mapConnections.begin(); it != m_mapConnections.end(); )
			{
				if (it->second.m_userID == remoteUserID)
				{
					NetworkLog(ELogVerbosity::LOG_RELEASE, "[ERASE] Removing user %lld", it->second.m_userID);
					it = m_mapConnections.erase(it);
					break;
				}
				else
				{
					++it;
				}
			}
		}
	}
}

void NetworkMesh::Disconnect()
{
	if (m_bDisconnected)
		return;

	m_bDisconnected = true;

	// Prevent final Steam connection callbacks from re-entering the mesh while
	// connections are being closed and the map is cleared.
	g_bNetworkMeshDestroying.store(true, std::memory_order_release);

    for (auto& connectionData : m_mapConnections)
    {
		connectionData.second.Close();
    }

    m_mapConnections.clear();

	if (AnticheatPlugInterface::DoesACPluginProvideSecureGameTransport())
	{
		AnticheatPlugInterface::DisconnectAll();
	}
	else
	{
		if (SteamNetworkingSockets() && m_hListenSock != k_HSteamListenSocket_Invalid)
		{
			SteamNetworkingSockets()->CloseListenSocket(m_hListenSock);
		}

		m_hListenSock = k_HSteamListenSocket_Invalid;
	}

	g_bNetworkMeshDestroying.store(false, std::memory_order_release);
}

void NetworkMesh::Tick()
{
	// state reported from anticheat plugin threads; UpdateState reaches UI callbacks, so apply it here
	std::vector<std::pair<int64_t, EConnectionState>> vecStateUpdates;
	{
		std::lock_guard<std::mutex> lock(m_pendingStateUpdatesMutex);
		vecStateUpdates.swap(m_vecPendingStateUpdates);
	}
	for (const auto& update : vecStateUpdates)
	{
		std::lock_guard<std::recursive_mutex> lock(m_mapConnectionsMutex);
		auto it = m_mapConnections.find(update.first);
		if (it != m_mapConnections.end())
		{
			it->second.UpdateState(update.second, this);
		}
	}

	if (!AnticheatPlugInterface::DoesACPluginProvideSecureGameTransport() && m_pSignaling != nullptr)
	{
		m_pSignaling->Poll();
	}

	// update connection histograms
	for (auto& kvPair : m_mapConnections)
	{
		PlayerConnection& conn = kvPair.second;
		conn.UpdateLatencyHistogram();
	}

	// the game transport isn't created until the game begins, but we want to transfer AC packets in the lobby first, so consider this a liteupdate
	if (TheNGMPGame != nullptr && !TheNGMPGame->isGameInProgress())
	{
		for (auto& kvPair : m_mapConnections)
		{
			kvPair.second.LiteUpdateForAC();
		}
	}
}

void PlayerConnection::LiteUpdateForAC()
{
	if (AnticheatPlugInterface::DoesACPluginProvideSecureGameTransport())
	{
		// EOS: Nothing to do here, AC packets are handled internally when MW is handling it
	}
	else
	{
		SteamNetworkingMessage_t* pMsg[255] = { nullptr };
		int numPackets = Recv(pMsg);

		if (numPackets <= 0)
			return;

		if (numPackets > static_cast<int>(std::size(pMsg)))
		{
			NetworkLog(ELogVerbosity::LOG_RELEASE,
				"Game Packet Recv: numPackets (%d) > pMsg capacity (%zu), clamping",
				numPackets, std::size(pMsg));
			numPackets = static_cast<int>(std::size(pMsg));
		}

		for (int iPacket = 0; iPacket < numPackets; ++iPacket)
		{
			SteamNetworkingMessage_t* msg = pMsg[iPacket];
			if (!msg)
			{
				// CRITICAL BUG FIX: Don't return early - continue loop to release remaining messages
				// Skipping null entry but continue processing others
				NetworkLog(ELogVerbosity::LOG_DEBUG, "[AC PACKET] Received null message at index %d", iPacket);
				continue;
			}

			const uint32_t numBytes = msg->m_cbSize;

			// is it an AC packet?
			// TODO_AC: Improve detection, just add a 'msg type' to the start of the packet
			std::vector<unsigned char> vecData;
			vecData.resize(numBytes);
			memcpy(vecData.data(), msg->GetData(), numBytes);

			// Check minimum packet size for AC header
			if (numBytes >= sizeof(ENetworkChannel))
			{
				ENetworkChannel netChannel = (ENetworkChannel)vecData[0];
				if (netChannel == ENetworkChannel::NETWORK_CHANNEL_AC)
				{
					NetworkLog(ELogVerbosity::LOG_RELEASE, "[AC PACKET] Received AC message of size %u from user %lld", numBytes, static_cast<long long>(m_userID));


					// remove header
					// TODO_AC: Optimize this
					std::vector<unsigned char> vecDataAC;
					vecDataAC.resize(numBytes - sizeof(ENetworkChannel));
					memcpy(vecDataAC.data(), (char*)msg->GetData() + sizeof(ENetworkChannel), numBytes - sizeof(ENetworkChannel));

					AnticheatPlugInterface::AC_NetworkMessageArrived(m_userID, vecDataAC.data(), numBytes - sizeof(ENetworkChannel));
					msg->Release();
					continue;
				}
			}
			else if (numBytes != -1 && numBytes < sizeof(ENetworkChannel))
			{
				// Malformed AC packet - too small for header
				NetworkLog(ELogVerbosity::LOG_RELEASE, "[AC PACKET] Dropping malformed AC packet - size %u is less than header size 3 from user %lld", numBytes, static_cast<long long>(m_userID));
				msg->Release();
				continue;
			}

			// not an AC packet, we dont care
			NetworkLog(ELogVerbosity::LOG_DEBUG, "[AC PACKET] Received NON AC message");
			msg->Release();
		}
	}
}

PlayerConnection::PlayerConnection(int64_t userID, HSteamNetConnection hSteamConnection)
{
	m_userID = userID;
	m_ConnectionType = EConnectionType::BuiltIn_ValveSockets;
	
	// no connection yet
	m_hSteamConnection = hSteamConnection;
	NetworkLog(ELogVerbosity::LOG_RELEASE, "[STEAM CONNECTION] Attaching connection %u to user %lld", hSteamConnection, userID);

	SteamNetworkingSockets()->SetConnectionName(hSteamConnection, std::format("Steam Connection User{}", userID).c_str());

	NetworkMesh* pMesh = NGMP_OnlineServicesManager::GetNetworkMesh();
	if (pMesh != nullptr)
	{
		pMesh->RegisterConnectivity(userID);
	}
}

PlayerConnection::PlayerConnection(int64_t userID, const char* szMiddlewareID)
{
    m_userID = userID;
    m_ConnectionType = EConnectionType::MiddlewarePluginGeneric;

    // no connection yet
    m_hSteamConnection = k_HSteamNetConnection_Invalid;
	m_strMiddlewareID = std::string(szMiddlewareID);

    NetworkLog(ELogVerbosity::LOG_RELEASE, "[MIDDLEWARE CONNECTION] Attaching connection %s to user %lld", szMiddlewareID, userID);

    NetworkMesh* pMesh = NGMP_OnlineServicesManager::GetNetworkMesh();
    if (pMesh != nullptr)
    {
        pMesh->RegisterConnectivity(userID);
    }
}

int PlayerConnection::SendGamePacket(void* pBuffer, uint32_t totalDataSize)
{
    if (totalDataSize == 0)
    {
        NetworkLog(ELogVerbosity::LOG_RELEASE, "[GAME PACKET] Cannot send empty game packet to user %lld", m_userID);
        return (int)k_EResultFail;
    }

    if (pBuffer == nullptr)
    {
        NetworkLog(ELogVerbosity::LOG_RELEASE, "[GAME PACKET] Cannot send game packet with null buffer to user %lld", m_userID);
        return (int)k_EResultFail;
    }

    if (AnticheatPlugInterface::DoesACPluginProvideSecureGameTransport())
    {
        // The plugin owns the transport send. A successful dispatch must not
        // fall through and be reported to NextGenTransport as a failed send.
        AnticheatPlugInterface::SendPacket(
            m_strMiddlewareID.c_str(), m_userID, pBuffer, totalDataSize,
            ENetworkChannels::Game, EPacketReliability::PACKET_RELIABILITY_RELIABLE_ORDERED);
        return (int)k_EResultOK;
    }

    if (m_hSteamConnection == k_HSteamNetConnection_Invalid)
    {
        NetworkLog(ELogVerbosity::LOG_RELEASE, "[GAME PACKET] Cannot send game packet - connection is invalid for user %lld", m_userID);
        return (int)k_EResultFail;
    }

    // Every send attempt must preserve the channel prefix expected by Recv().
    // In particular, the fallback must not send raw pBuffer: that shifts packet
    // framing and makes the receiver interpret the wrong byte as the header.
    const ENetworkChannel netChannel = ENetworkChannel::NETWORK_CHANNEL_GAME;
    std::vector<BYTE> vecData(totalDataSize + sizeof(ENetworkChannel));
    vecData[0] = (BYTE)netChannel;
    memcpy(vecData.data() + sizeof(ENetworkChannel), pBuffer, totalDataSize);

    int sendFlags = k_nSteamNetworkingSend_Reliable | k_nSteamNetworkingSend_AutoRestartBrokenSession;
    ServiceConfig& serviceConf = NGMP_OnlineServicesManager::GetInstance()->GetServiceConfig();
    const int netSendFlags = serviceConf.network_send_flags;

    EResult result = SteamNetworkingSockets()->SendMessageToConnection(
        m_hSteamConnection, vecData.data(), (int)vecData.size(), sendFlags, nullptr);

    if (result == k_EResultOK)
    {
        return (int)result;
    }

    // Only use configured fallback flags after the default reliable send fails.
    if (netSendFlags != -1)
    {
        if (netSendFlags == 0)
            sendFlags = k_nSteamNetworkingSend_Unreliable;
        else if (netSendFlags == 1)
            sendFlags = k_nSteamNetworkingSend_UnreliableNoNagle;
        else if (netSendFlags == 2)
            sendFlags = k_nSteamNetworkingSend_UnreliableNoDelay;
        else if (netSendFlags == 3)
            sendFlags = k_nSteamNetworkingSend_Reliable;
        else if (netSendFlags == 4)
            sendFlags = k_nSteamNetworkingSend_ReliableNoNagle;
    }

    NetworkLog(ELogVerbosity::LOG_DEBUG,
        "[GAME PACKET] Default send failed (%d); retrying framed packet with configured flags %d for user %lld",
        (int)result, sendFlags, (long long)m_userID);

    result = SteamNetworkingSockets()->SendMessageToConnection(
        m_hSteamConnection, vecData.data(), (int)vecData.size(), sendFlags, nullptr);

    if (result != k_EResultOK)
    {
        NetworkLog(ELogVerbosity::LOG_RELEASE,
            "[GAME PACKET] Failed to send framed packet, err code was %d for user %lld",
            (int)result, (long long)m_userID);
    }

    return (int)result;
}

int PlayerConnection::GetLatency()
{
	if (m_ConnectionType == EConnectionType::MiddlewarePluginGeneric)
	{
		return AnticheatPlugInterface::GetConnectionLatencyForUser(m_strMiddlewareID.c_str(), m_userID);
	}
	else
	{
        // TODO_STEAM: consider using lanes
        if (m_hSteamConnection != k_HSteamNetConnection_Invalid)
        {
            const int k_nLanes = 1;
            SteamNetConnectionRealTimeStatus_t status;
            SteamNetConnectionRealTimeLaneStatus_t laneStatus[k_nLanes];



            EResult res = SteamNetworkingSockets()->GetConnectionRealTimeStatus(m_hSteamConnection, &status, k_nLanes, laneStatus);
            if (res == k_EResultOK)
            {
                return status.m_nPing;
            }
        }
	}

	return -1;
}

int PlayerConnection::GetJitter()
{
	int sumDelta = 0;
	int count = 0;
	int prev = -1;
	for (int sample : m_vecLatencyHistory)
	{
		if (sample >= 0)
		{
			if (prev >= 0)
			{
				sumDelta += std::abs(sample - prev);
				++count;
			}
			prev = sample;
		}
		else
		{
			prev = -1; // gap in valid data
		}
	}

	if (count < 10)
		return -1;

	return sumDelta / count;
}

float PlayerConnection::GetConnectionQuality()
{
	if (!m_vecQualityHistory.empty())
	{
		float sum = 0.0f;
		for (float r : m_vecQualityHistory)
			sum += r;
		return sum / static_cast<float>(m_vecQualityHistory.size());
	}

	return -1.0f;
}

int PlayerConnection::ComputeConnectionScore()
{
	static constexpr std::chrono::milliseconds k_warmupDuration{ 1000 };
	if (m_connectedSinceTime == (std::chrono::steady_clock::time_point::min)() ||
		std::chrono::steady_clock::now() - m_connectedSinceTime < k_warmupDuration)
	{
		return -1;
	}

	// TODO_EOS: need to impl jitter etc again
	const int latency = GetLatency();
	const int jitter = GetJitter();
	const float quality = GetConnectionQuality();   // packet delivery ratio [0..1]

	static constexpr float k_subScoreFloor = 0.3f;
	static constexpr float k_latencyWeight = 0.30f;
	static constexpr float k_jitterWeight = 0.25f;
	static constexpr float k_reliabilityWeight = 0.45f;

	float weightedLogSum = 0.0f;
	float activeWeightSum = 0.0f;

	if (latency >= 0)
	{
		// 10ms and below are treated as full score. Above that, roughly:
		// 400ms -> composite 75, 800ms -> composite 50 when other metrics are perfect.
		int effectiveLatency = (std::max)(latency - 10, 0);
		float latFactor = std::clamp(1.0f - static_cast<float>(effectiveLatency) / 1590.0f, 0.0f, 1.0f);
		float latencyScore = (std::max)(std::powf(latFactor, 4.545f), k_subScoreFloor);
		weightedLogSum += k_latencyWeight * std::logf(latencyScore);
		activeWeightSum += k_latencyWeight;
	}

	if (jitter >= 0)
	{
		// 50ms -> composite 75, 100ms -> composite 50 when other metrics are perfect.
		float jitFactor = std::clamp(1.0f - static_cast<float>(jitter) / 200.0f, 0.0f, 1.0f);
		float jitterScore = (std::max)(std::powf(jitFactor, 2.632f), k_subScoreFloor);
		weightedLogSum += k_jitterWeight * std::logf(jitterScore);
		activeWeightSum += k_jitterWeight;
	}

	if (quality >= 0.0f)
	{
		// 90% -> composite 75, 80% -> composite 50 when other metrics are perfect.
		float relFactor = std::clamp(2.5f * quality - 1.5f, 0.0f, 1.0f);
		float reliabilityScore = (std::max)(std::powf(relFactor, 2.5f), k_subScoreFloor);
		weightedLogSum += k_reliabilityWeight * std::logf(reliabilityScore);
		activeWeightSum += k_reliabilityWeight;
	}

	if (activeWeightSum <= 0.0f)
	{
		return -1;
	}

	float composite = std::expf(weightedLogSum / activeWeightSum);
	float rawScore = composite * 100.0f;

	static constexpr float k_scoreSmoothingAlpha = 0.15f;
	if (m_smoothedScore < 0.0f)
	{
		m_smoothedScore = rawScore;
	}
	else
	{
		m_smoothedScore += k_scoreSmoothingAlpha * (rawScore - m_smoothedScore);
	}

	return static_cast<int>(std::round(m_smoothedScore));
}

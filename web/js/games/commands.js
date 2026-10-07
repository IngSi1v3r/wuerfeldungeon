// Eine verloren gegangene Antwort darf kein zweites Spiel / keinen zweiten
// Spielstart erzeugen. Auch ein manueller Retry derselben Aktion nutzt die UUID.
export class GameCommands {
  constructor(api) {this.api=api;this.pending=null;this.busy=false;}
  async run(name,params) {
    if(this.busy) throw Error('Die vorige Aktion wird noch gespeichert.');
    const key=JSON.stringify([name,params]);
    if(this.pending?.key!==key)this.pending={key,name,params:{...params,p_request_id:crypto.randomUUID()}};
    this.busy=true;
    try {
      let answer;
      for(let attempt=0;attempt<2;attempt++) {
        try {answer=await this.api.authRpc(name,this.pending.params);break;}
        catch(error){if(!['NETWORK','TIMEOUT','SERVER_ERROR'].includes(error.code)||attempt===1)throw error;}
      }
      this.pending=null;return answer;
    } catch(error) {if(!['NETWORK','TIMEOUT','SERVER_ERROR'].includes(error.code))this.pending=null;throw error;}
    finally {this.busy=false;}
  }
}

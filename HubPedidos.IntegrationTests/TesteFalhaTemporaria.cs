using Xunit;
namespace HubPedidos.IntegrationTests;

public sealed class TesteFalhaTemporaria
{
    [Fact]
    public void R8_Gate_Deve_Bloquear_Teste_Falho() => Assert.True(false, "Falha deliberada para a evidencia R8.04");
}
